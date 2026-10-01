import Foundation

// MARK: - JSON Schema validation (tool arguments, artifacts)

/// A schema that cannot be used to validate anything: not a JSON Schema
/// object, an unsupported dialect or keyword, a malformed keyword, a
/// pattern that does not compile, or a `$ref` that does not resolve.
/// Validation fails closed: a call whose tool has such a schema is refused.
public struct InputSchemaError: Error, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The JSON Schema dialects the validator runs.
public enum JSONSchemaDialect: String, Sendable {
    case draft2020_12 = "2020-12"
    case draft2019_09 = "2019-09"
    case draft07 = "draft-07"
}

/// A compiled JSON Schema, checked once and applied to many instances.
///
/// Dialect: a schema without `$schema` is 2020-12 (the MCP default);
/// `$schema` may name 2020-12, 2019-09 or draft-07, and draft-04/06 are
/// validated with draft-07 rules. Any other `$schema` is refused.
///
/// Assertions: `type`, `enum`, `const`, `multipleOf`, `minimum`,
/// `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
/// `maxLength` (Unicode code points), `pattern`, `items`, `prefixItems`,
/// `additionalItems`, `minItems`, `maxItems`, `uniqueItems`, `contains`,
/// `minContains`, `maxContains`, `properties`, `patternProperties`,
/// `additionalProperties`, `propertyNames`, `required`, `minProperties`,
/// `maxProperties`, `dependentRequired`, `dependentSchemas`,
/// `dependencies`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
/// boolean schemas, and `$ref` to the same document (`#`, JSON pointers
/// such as `#/$defs/x`, and `$anchor`s).
///
/// Not supported, and refused (fail closed) when a schema uses them:
/// `unevaluatedProperties`, `unevaluatedItems`, `$dynamicRef`,
/// `$recursiveRef` and `$ref`s to other documents. `format` is not
/// asserted (an annotation in 2020-12, as in @smallchat/core), and unknown
/// keywords are ignored. Patterns use the platform regular-expression
/// engine (ICU), whose syntax differs from ECMAScript's in rare corners.
///
/// Semantics are exactly the schema's: `additionalProperties: false`
/// rejects unknown arguments, an open schema accepts them. Types are not
/// coerced. A number is an `integer` when its value is integral (`2.0`
/// is), as in JavaScript.
public struct JSONSchemaValidator: Sendable {
    public let dialect: JSONSchemaDialect
    private let root: AnyCodableValue
    private let anchors: [String: AnyCodableValue]
    private let regexes: RegexTable

    /// Keywords whose semantics this validator does not implement.
    public static let unsupportedKeywords: Set<String> = [
        "unevaluatedProperties", "unevaluatedItems", "$dynamicRef", "$recursiveRef",
    ]

    /// Errors reported per validation; the rest are summarized.
    public static let maxErrors = 20

    /// Compile `schema`. Throws `InputSchemaError` when it cannot be used.
    public init(schema: AnyCodableValue) throws {
        guard case .dict(let object) = schema else {
            throw InputSchemaError("inputSchema must be a JSON Schema object")
        }
        var root = schema
        switch object["$schema"] {
        case nil:
            dialect = .draft2020_12
        case .string(let uri)?:
            if uri.contains("/2020-12/") {
                dialect = .draft2020_12
            } else if uri.contains("/2019-09/") {
                dialect = .draft2019_09
            } else if uri.contains("/draft-07/schema") {
                dialect = .draft07
            } else if uri.contains("/draft-04/schema") || uri.contains("/draft-06/schema") {
                dialect = .draft07
                var stripped = object
                stripped.removeValue(forKey: "$schema")
                root = .dict(stripped)
            } else {
                throw InputSchemaError("inputSchema uses an unsupported JSON Schema dialect: \(uri)")
            }
        default:
            throw InputSchemaError("inputSchema.$schema must be a string")
        }
        self.root = root

        var compiler = SchemaCompiler(dialect: dialect, root: root)
        try compiler.check(root, at: "#")
        self.anchors = compiler.anchors
        self.regexes = RegexTable(compiler.patterns)
        // Every $ref must resolve.
        for ref in compiler.refs where resolve(ref) == nil {
            throw InputSchemaError("inputSchema has a $ref that cannot be resolved: \(ref)")
        }
    }

    /// Compile a schema given as JSON text.
    public init(json: String) throws {
        let value: AnyCodableValue
        do {
            value = try parseJSON(json)
        } catch {
            throw InputSchemaError("schema is not valid JSON: \(error)")
        }
        try self.init(schema: value)
    }

    /// Validate `instance`. Returns the errors (empty when valid), at most
    /// `maxErrors` of them plus a summary line.
    public func validate(_ instance: AnyCodableValue) -> [ValidationError] {
        var errors: [ValidationError] = []
        let run = Run(validator: self, root: instance)
        run.validate(root, instance, at: "", errors: &errors, refDepth: 0)
        if errors.count > Self.maxErrors {
            let extra = errors.count - Self.maxErrors
            errors = Array(errors.prefix(Self.maxErrors))
            errors.append(ValidationError(path: "", message: "\(extra) more validation error(s) not shown"))
        }
        return errors
    }

    /// Whether `instance` is valid.
    public func isValid(_ instance: AnyCodableValue) -> Bool {
        validate(instance).isEmpty
    }

    // MARK: References

    fileprivate func resolve(_ ref: String) -> AnyCodableValue? {
        var fragment = ref
        if !ref.hasPrefix("#") {
            // Only references into this document, by its own $id.
            guard case .dict(let rootObject) = root, case .string(let id)? = rootObject["$id"], ref.hasPrefix(id) else { return nil }
            fragment = String(ref.dropFirst(id.count))
            if fragment.isEmpty { return root }
            guard fragment.hasPrefix("#") else { return nil }
        }
        let pointer = String(fragment.dropFirst())
        if pointer.isEmpty { return root }
        if !pointer.hasPrefix("/") {
            return anchors[pointer.removingPercentEncoding ?? pointer]
        }
        var current = root
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = (String(raw).removingPercentEncoding ?? String(raw))
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .dict(let object):
                guard let next = object[token] else { return nil }
                current = next
            case .array(let items):
                guard let index = Int(token), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    fileprivate func regex(_ pattern: String) -> NSRegularExpression? {
        regexes.table[pattern]
    }
}

// MARK: - Compilation checks

/// Compiled regular expressions (immutable once built).
private final class RegexTable: @unchecked Sendable {
    let table: [String: NSRegularExpression]
    init(_ table: [String: NSRegularExpression]) { self.table = table }
}

private let typeNames: Set<String> = ["null", "boolean", "object", "array", "number", "string", "integer"]

private struct SchemaCompiler {
    let dialect: JSONSchemaDialect
    let root: AnyCodableValue
    var anchors: [String: AnyCodableValue] = [:]
    var patterns: [String: NSRegularExpression] = [:]
    var refs: [String] = []

    init(dialect: JSONSchemaDialect, root: AnyCodableValue) {
        self.dialect = dialect
        self.root = root
    }

    func fail(_ at: String, _ message: String) -> InputSchemaError {
        InputSchemaError("inputSchema is not a valid JSON Schema (\(dialect.rawValue)): \(message) at \(at)")
    }

    mutating func compilePattern(_ pattern: String, at: String) throws {
        if patterns[pattern] != nil { return }
        do {
            patterns[pattern] = try NSRegularExpression(pattern: pattern)
        } catch {
            throw fail(at, "pattern \"\(pattern)\" does not compile")
        }
    }

    mutating func check(_ schema: AnyCodableValue, at: String) throws {
        let object: [String: AnyCodableValue]
        switch schema {
        case .bool: return
        case .dict(let o): object = o
        default: throw fail(at, "a schema must be an object or a boolean")
        }

        for keyword in object.keys where JSONSchemaValidator.unsupportedKeywords.contains(keyword) {
            throw InputSchemaError("inputSchema uses \(keyword), which smallchat does not support (at \(at)); nothing can be validated against it")
        }

        if let type = object["type"] {
            switch type {
            case .string(let name):
                guard typeNames.contains(name) else { throw fail(at, "unknown type \"\(name)\"") }
            case .array(let names):
                for name in names {
                    guard case .string(let n) = name, typeNames.contains(n) else { throw fail(at, "type must name JSON types") }
                }
            default:
                throw fail(at, "type must be a string or an array of strings")
            }
        }
        if let required = object["required"] {
            guard case .array(let names) = required, names.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw fail(at, "required must be an array of strings")
            }
        }
        if let values = object["enum"] {
            guard case .array = values else { throw fail(at, "enum must be an array") }
        }
        for keyword in ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "minContains", "maxContains"] {
            if let value = object[keyword] {
                guard let n = number(value), n >= 0, n.rounded() == n else { throw fail(at, "\(keyword) must be a non-negative integer") }
            }
        }
        for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
            if let value = object[keyword] {
                if case .bool = value {
                    throw fail(at, "\(keyword) must be a number (the boolean form is draft-04, which is validated as draft-07)")
                }
                guard number(value) != nil else { throw fail(at, "\(keyword) must be a number") }
            }
        }
        if let value = object["multipleOf"] {
            guard let n = number(value), n > 0 else { throw fail(at, "multipleOf must be a number greater than 0") }
        }
        if let value = object["pattern"] {
            guard case .string(let pattern) = value else { throw fail(at, "pattern must be a string") }
            try compilePattern(pattern, at: at)
        }
        if let value = object["$ref"] {
            guard case .string(let ref) = value else { throw fail(at, "$ref must be a string") }
            refs.append(ref)
        }
        if case .string(let anchor)? = object["$anchor"] {
            anchors[anchor] = schema
        }
        if case .string(let id)? = object["$id"], id.hasPrefix("#"), id.count > 1 {
            anchors[String(id.dropFirst())] = schema
        }

        // Subschemas
        for keyword in ["not", "if", "then", "else", "contains", "propertyNames", "additionalProperties", "additionalItems"] {
            if let sub = object[keyword] { try check(sub, at: "\(at)/\(keyword)") }
        }
        for keyword in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"] {
            guard let value = object[keyword] else { continue }
            guard case .dict(let subs) = value else { throw fail(at, "\(keyword) must be an object") }
            for (name, sub) in subs {
                if keyword == "patternProperties" { try compilePattern(name, at: "\(at)/patternProperties") }
                try check(sub, at: "\(at)/\(keyword)/\(name)")
            }
        }
        if let value = object["dependencies"] {
            guard case .dict(let deps) = value else { throw fail(at, "dependencies must be an object") }
            for (name, dep) in deps {
                if case .array = dep { continue }
                try check(dep, at: "\(at)/dependencies/\(name)")
            }
        }
        if let value = object["dependentRequired"] {
            guard case .dict = value else { throw fail(at, "dependentRequired must be an object") }
        }
        for keyword in ["allOf", "anyOf", "oneOf"] {
            guard let value = object[keyword] else { continue }
            guard case .array(let subs) = value, !subs.isEmpty else { throw fail(at, "\(keyword) must be a non-empty array") }
            for (i, sub) in subs.enumerated() { try check(sub, at: "\(at)/\(keyword)/\(i)") }
        }
        if let value = object["items"] {
            if case .array(let subs) = value {
                guard dialect != .draft2020_12 else { throw fail(at, "items must be a schema in 2020-12 (use prefixItems for tuples)") }
                for (i, sub) in subs.enumerated() { try check(sub, at: "\(at)/items/\(i)") }
            } else {
                try check(value, at: "\(at)/items")
            }
        }
        if let value = object["prefixItems"] {
            guard case .array(let subs) = value else { throw fail(at, "prefixItems must be an array") }
            for (i, sub) in subs.enumerated() { try check(sub, at: "\(at)/prefixItems/\(i)") }
        }
    }
}

private func number(_ value: AnyCodableValue) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d.isFinite ? d : nil
    default: return nil
    }
}

// MARK: - Validation

private struct Run {
    let validator: JSONSchemaValidator
    let root: AnyCodableValue

    var dialect: JSONSchemaDialect { validator.dialect }

    func isValid(_ schema: AnyCodableValue, _ instance: AnyCodableValue, at: String, refDepth: Int) -> Bool {
        var errors: [ValidationError] = []
        validate(schema, instance, at: at, errors: &errors, refDepth: refDepth)
        return errors.isEmpty
    }

    func validate(_ schema: AnyCodableValue, _ instance: AnyCodableValue, at: String, errors: inout [ValidationError], refDepth: Int) {
        let object: [String: AnyCodableValue]
        switch schema {
        case .bool(let allowed):
            if !allowed { errors.append(generic(at, instance, "is not allowed (boolean schema false)")) }
            return
        case .dict(let o):
            object = o
        default:
            return
        }

        if case .string(let ref)? = object["$ref"] {
            guard refDepth < 64, let target = validator.resolve(ref) else {
                errors.append(ValidationError(path: at, message: "\(label(at)) cannot be validated: $ref \(ref) recurses too deeply"))
                return
            }
            validate(target, instance, at: at, errors: &errors, refDepth: refDepth + 1)
            // In draft-07, keywords beside $ref are ignored.
            if dialect == .draft07 { return }
        }

        if let type = object["type"], !matchesType(type, instance) {
            let expected: String
            switch type {
            case .string(let t): expected = t
            case .array(let ts): expected = ts.compactMap { if case .string(let t) = $0 { return t }; return nil }.joined(separator: ",")
            default: expected = "?"
            }
            errors.append(ValidationError(
                path: at,
                message: "\(label(at)) must be \(expected), got \(kindOf(instance)) \(preview(instance))",
                expected: expected,
                received: preview(instance)
            ))
        }

        if case .array(let allowed)? = object["enum"], !allowed.contains(where: { jsonEqual($0, instance) }) {
            let list = allowed.map(compactJSON).joined(separator: ", ")
            errors.append(ValidationError(
                path: at,
                message: "\(label(at)) must be one of \(list), got \(preview(instance))",
                expected: "one of \(list)",
                received: preview(instance)
            ))
        }
        if let constant = object["const"], !jsonEqual(constant, instance) {
            errors.append(ValidationError(
                path: at,
                message: "\(label(at)) must be \(compactJSON(constant)), got \(preview(instance))",
                expected: compactJSON(constant),
                received: preview(instance)
            ))
        }

        if let x = numericValue(instance) {
            validateNumber(object, x, instance, at: at, errors: &errors)
        }
        if case .string(let s) = instance {
            validateString(object, s, instance, at: at, errors: &errors)
        }
        if case .array(let items) = instance {
            validateArray(object, items, instance, at: at, errors: &errors, refDepth: refDepth)
        }
        if case .dict(let properties) = instance {
            validateObject(object, properties, instance, at: at, errors: &errors, refDepth: refDepth)
        }

        if case .array(let subs)? = object["allOf"] {
            for sub in subs { validate(sub, instance, at: at, errors: &errors, refDepth: refDepth) }
        }
        if case .array(let subs)? = object["anyOf"], !subs.contains(where: { isValid($0, instance, at: at, refDepth: refDepth) }) {
            errors.append(generic(at, instance, "must match a schema in anyOf"))
        }
        if case .array(let subs)? = object["oneOf"] {
            let matching = subs.filter { isValid($0, instance, at: at, refDepth: refDepth) }.count
            if matching != 1 {
                errors.append(generic(at, instance, "must match exactly one schema in oneOf (matches \(matching))"))
            }
        }
        if let sub = object["not"], isValid(sub, instance, at: at, refDepth: refDepth) {
            errors.append(generic(at, instance, "must NOT be valid against the \"not\" schema"))
        }
        if let condition = object["if"] {
            if isValid(condition, instance, at: at, refDepth: refDepth) {
                if let then = object["then"], !isValid(then, instance, at: at, refDepth: refDepth) {
                    validate(then, instance, at: at, errors: &errors, refDepth: refDepth)
                }
            } else if let otherwise = object["else"], !isValid(otherwise, instance, at: at, refDepth: refDepth) {
                validate(otherwise, instance, at: at, errors: &errors, refDepth: refDepth)
            }
        }
    }

    // MARK: Numbers

    func validateNumber(_ object: [String: AnyCodableValue], _ x: Double, _ instance: AnyCodableValue, at: String, errors: inout [ValidationError]) {
        guard x.isFinite else { return }  // type checks already reject non-finite numbers
        if let m = object["multipleOf"].flatMap(number) {
            let q = x / m
            if !(q.isFinite && q.rounded() == q) { errors.append(generic(at, instance, "must be multiple of \(fmt(m))")) }
        }
        if let limit = object["minimum"].flatMap(number), x < limit { errors.append(generic(at, instance, "must be >= \(fmt(limit))")) }
        if let limit = object["maximum"].flatMap(number), x > limit { errors.append(generic(at, instance, "must be <= \(fmt(limit))")) }
        if let limit = object["exclusiveMinimum"].flatMap(number), x <= limit { errors.append(generic(at, instance, "must be > \(fmt(limit))")) }
        if let limit = object["exclusiveMaximum"].flatMap(number), x >= limit { errors.append(generic(at, instance, "must be < \(fmt(limit))")) }
    }

    // MARK: Strings

    func validateString(_ object: [String: AnyCodableValue], _ s: String, _ instance: AnyCodableValue, at: String, errors: inout [ValidationError]) {
        let length = s.unicodeScalars.count
        if let n = object["minLength"].flatMap(number), Double(length) < n {
            errors.append(generic(at, instance, "must NOT have fewer than \(fmt(n)) characters"))
        }
        if let n = object["maxLength"].flatMap(number), Double(length) > n {
            errors.append(generic(at, instance, "must NOT have more than \(fmt(n)) characters"))
        }
        if case .string(let pattern)? = object["pattern"], let regex = validator.regex(pattern) {
            let range = NSRange(s.startIndex..., in: s)
            if regex.firstMatch(in: s, range: range) == nil {
                errors.append(generic(at, instance, "must match pattern \"\(pattern)\""))
            }
        }
    }

    // MARK: Arrays

    func validateArray(_ object: [String: AnyCodableValue], _ items: [AnyCodableValue], _ instance: AnyCodableValue, at: String, errors: inout [ValidationError], refDepth: Int) {
        var tupleLength = 0
        if dialect == .draft2020_12 {
            if case .array(let prefix)? = object["prefixItems"] {
                tupleLength = prefix.count
                for (i, sub) in prefix.enumerated() where i < items.count {
                    validate(sub, items[i], at: "\(at)/\(i)", errors: &errors, refDepth: refDepth)
                }
            }
            if let rest = object["items"] {
                for i in tupleLength..<max(tupleLength, items.count) {
                    validate(rest, items[i], at: "\(at)/\(i)", errors: &errors, refDepth: refDepth)
                }
            }
        } else if let itemsSchema = object["items"] {
            if case .array(let tuple) = itemsSchema {
                tupleLength = tuple.count
                for (i, sub) in tuple.enumerated() where i < items.count {
                    validate(sub, items[i], at: "\(at)/\(i)", errors: &errors, refDepth: refDepth)
                }
                if let extra = object["additionalItems"] {
                    if case .bool(false) = extra, items.count > tupleLength {
                        errors.append(generic(at, instance, "must NOT have more than \(tupleLength) items"))
                    } else {
                        for i in tupleLength..<max(tupleLength, items.count) {
                            validate(extra, items[i], at: "\(at)/\(i)", errors: &errors, refDepth: refDepth)
                        }
                    }
                }
            } else {
                for (i, item) in items.enumerated() {
                    validate(itemsSchema, item, at: "\(at)/\(i)", errors: &errors, refDepth: refDepth)
                }
            }
        }

        if let n = object["minItems"].flatMap(number), Double(items.count) < n {
            errors.append(generic(at, instance, "must NOT have fewer than \(fmt(n)) items"))
        }
        if let n = object["maxItems"].flatMap(number), Double(items.count) > n {
            errors.append(generic(at, instance, "must NOT have more than \(fmt(n)) items"))
        }
        if case .bool(true)? = object["uniqueItems"] {
            outer: for i in items.indices {
                for j in items.indices where j > i && jsonEqual(items[i], items[j]) {
                    errors.append(generic(at, instance, "must NOT have duplicate items (items ## \(j) and \(i) are identical)"))
                    break outer
                }
            }
        }
        if let contains = object["contains"] {
            let count = items.filter { isValid(contains, $0, at: at, refDepth: refDepth) }.count
            let minimum = dialect == .draft07 ? 1 : (object["minContains"].flatMap(number).map { Int($0) } ?? 1)
            if count < minimum {
                errors.append(generic(at, instance, "must contain at least \(minimum) valid item(s)"))
            }
            if dialect != .draft07, let maximum = object["maxContains"].flatMap(number).map({ Int($0) }), count > maximum {
                errors.append(generic(at, instance, "must contain at most \(maximum) valid item(s)"))
            }
        }
    }

    // MARK: Objects

    func validateObject(_ object: [String: AnyCodableValue], _ properties: [String: AnyCodableValue], _ instance: AnyCodableValue, at: String, errors: inout [ValidationError], refDepth: Int) {
        if case .array(let names)? = object["required"] {
            for case .string(let name) in names where properties[name] == nil {
                let path = "\(at)/\(escapePointer(name))"
                errors.append(ValidationError(path: path, message: "missing required argument \(quoted(path))", expected: "a value"))
            }
        }

        var declared: [String: AnyCodableValue] = [:]
        if case .dict(let props)? = object["properties"] { declared = props }
        var patterns: [(NSRegularExpression, AnyCodableValue)] = []
        if case .dict(let props)? = object["patternProperties"] {
            for (pattern, sub) in props.sorted(by: { $0.key < $1.key }) {
                if let regex = validator.regex(pattern) { patterns.append((regex, sub)) }
            }
        }

        for name in properties.keys.sorted() {
            let value = properties[name]!
            let path = "\(at)/\(escapePointer(name))"
            var matched = false
            if let sub = declared[name] {
                matched = true
                validate(sub, value, at: path, errors: &errors, refDepth: refDepth)
            }
            let range = NSRange(name.startIndex..., in: name)
            for (regex, sub) in patterns where regex.firstMatch(in: name, range: range) != nil {
                matched = true
                validate(sub, value, at: path, errors: &errors, refDepth: refDepth)
            }
            if !matched, let additional = object["additionalProperties"] {
                if case .bool(false) = additional {
                    errors.append(ValidationError(
                        path: path,
                        message: "unknown argument \(quoted(path)): the tool's inputSchema does not allow it",
                        received: preview(value)
                    ))
                } else {
                    validate(additional, value, at: path, errors: &errors, refDepth: refDepth)
                }
            }
            if let names = object["propertyNames"], !isValid(names, .string(name), at: path, refDepth: refDepth) {
                errors.append(ValidationError(path: path, message: "property name \(compactJSON(.string(name))) is invalid"))
            }
        }

        if let n = object["minProperties"].flatMap(number), Double(properties.count) < n {
            errors.append(generic(at, instance, "must NOT have fewer than \(fmt(n)) properties"))
        }
        if let n = object["maxProperties"].flatMap(number), Double(properties.count) > n {
            errors.append(generic(at, instance, "must NOT have more than \(fmt(n)) properties"))
        }

        var dependentRequired: [String: AnyCodableValue] = [:]
        var dependentSchemas: [String: AnyCodableValue] = [:]
        if dialect == .draft07 {
            if case .dict(let deps)? = object["dependencies"] {
                for (name, dep) in deps {
                    if case .array = dep { dependentRequired[name] = dep } else { dependentSchemas[name] = dep }
                }
            }
        } else {
            if case .dict(let deps)? = object["dependentRequired"] { dependentRequired = deps }
            if case .dict(let deps)? = object["dependentSchemas"] { dependentSchemas = deps }
        }
        for name in dependentRequired.keys.sorted() where properties[name] != nil {
            guard case .array(let needed)? = dependentRequired[name] else { continue }
            for case .string(let other) in needed where properties[other] == nil {
                errors.append(generic(at, instance, "must have property \(other) when property \(name) is present"))
            }
        }
        for name in dependentSchemas.keys.sorted() where properties[name] != nil {
            validate(dependentSchemas[name]!, instance, at: at, errors: &errors, refDepth: refDepth)
        }
    }

    // MARK: Messages

    func generic(_ at: String, _ instance: AnyCodableValue, _ message: String) -> ValidationError {
        ValidationError(path: at, message: "\(label(at)) \(message), got \(preview(instance))", received: preview(instance))
    }
}

private func matchesType(_ type: AnyCodableValue, _ instance: AnyCodableValue) -> Bool {
    switch type {
    case .string(let name): return matchesType(name, instance)
    case .array(let names): return names.contains { if case .string(let n) = $0 { return matchesType(n, instance) }; return false }
    default: return true
    }
}

private func matchesType(_ name: String, _ instance: AnyCodableValue) -> Bool {
    switch (name, instance) {
    case ("null", .null), ("boolean", .bool), ("object", .dict), ("array", .array), ("string", .string):
        return true
    case ("number", .int):
        return true
    case ("number", .double(let d)):
        return d.isFinite
    case ("integer", .int):
        return true
    case ("integer", .double(let d)):
        return d.isFinite && d.rounded() == d
    default:
        return false
    }
}

private func numericValue(_ value: AnyCodableValue) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d
    default: return nil
    }
}

/// JSON equality: numbers compare by value (`1` equals `1.0`), objects by members.
func jsonEqual(_ a: AnyCodableValue, _ b: AnyCodableValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.bool(let x), .bool(let y)): return x == y
    case (.string(let x), .string(let y)): return x == y
    case (.int, _), (.double, _):
        guard let x = numericValue(a), let y = numericValue(b) else { return false }
        return x == y
    case (.array(let x), .array(let y)):
        return x.count == y.count && zip(x, y).allSatisfy(jsonEqual)
    case (.dict(let x), .dict(let y)):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { jsonEqual(value, $0) } ?? false }
    default:
        return false
    }
}

private func kindOf(_ value: AnyCodableValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "boolean"
    case .string: return "string"
    case .array: return "array"
    case .dict: return "object"
    case .int: return "integer"
    case .double(let d): return d.isFinite && d.rounded() == d ? "integer" : "number"
    }
}

private func compactJSON(_ value: AnyCodableValue) -> String {
    if let text = try? canonicalJSON(value) { return text }
    if case .double(let d) = value { return String(d) }
    return "?"
}

private func preview(_ value: AnyCodableValue) -> String {
    let text = compactJSON(value)
    return text.count > 80 ? String(text.prefix(77)) + "..." : text
}

private func fmt(_ x: Double) -> String {
    (try? ecmaScriptNumberString(x)) ?? String(x)
}

/// "arguments" for the root, otherwise `argument "filter[0].name"`.
private func label(_ pointer: String) -> String {
    pointer.isEmpty ? "arguments" : "argument \(quoted(pointer))"
}

/// A JSON pointer as a quoted, readable path: "/filter/0/name" -> "filter[0].name".
private func quoted(_ pointer: String) -> String {
    let segments = pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
    var display = ""
    for (i, segment) in segments.enumerated() {
        if !segment.isEmpty, segment.allSatisfy(\.isASCII), segment.allSatisfy(\.isNumber) {
            display += "[\(segment)]"
        } else {
            display += i == 0 ? segment : ".\(segment)"
        }
    }
    return "\"\(display)\""
}

private func escapePointer(_ segment: String) -> String {
    segment.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}
