import Foundation

// MARK: - JSON Canonicalization Scheme (RFC 8785)

/// A value that has no canonical JSON form (a non-finite number, or a
/// native value that is not JSON).
public struct CanonicalJSONError: Error, Sendable, CustomStringConvertible {
    /// Where the value sits, as a JavaScript-style path (`$.a[0]`).
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String { "canonicalJSON: \(reason) at \(path)" }
}

/// The RFC 8785 (JCS) canonical form of a JSON value: object members sorted
/// by the UTF-16 code units of their names, no insignificant whitespace,
/// strings escaped as ECMAScript `JSON.stringify` escapes them, and numbers
/// in ECMAScript shortest round-trip form (`1e21` → `1e+21`, `-0` → `0`,
/// `2.0` → `2`).
///
/// This is the byte form the suite hashes (artifact content hashes, call
/// digests, proof digests), so two implementations that agree on a value
/// agree on its bytes. `.int` and `.double` are formatted alike, as the
/// double they denote. Throws `CanonicalJSONError` for NaN or ±Infinity,
/// which JSON cannot express.
public func canonicalJSON(_ value: AnyCodableValue) throws -> String {
    var out = ""
    try appendCanonical(value, path: "$", to: &out)
    return out
}

private func appendCanonical(_ value: AnyCodableValue, path: String, to out: inout String) throws {
    switch value {
    case .null:
        out += "null"
    case .bool(let b):
        out += b ? "true" : "false"
    case .int(let i):
        out += try ecmaScriptNumberString(Double(i), path: path)
    case .double(let d):
        out += try ecmaScriptNumberString(d, path: path)
    case .string(let s):
        appendQuoted(s, to: &out)
    case .array(let items):
        out += "["
        for (i, item) in items.enumerated() {
            if i > 0 { out += "," }
            try appendCanonical(item, path: "\(path)[\(i)]", to: &out)
        }
        out += "]"
    case .dict(let object):
        out += "{"
        let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for (i, key) in keys.enumerated() {
            if i > 0 { out += "," }
            appendQuoted(key, to: &out)
            out += ":"
            try appendCanonical(object[key]!, path: "\(path).\(key)", to: &out)
        }
        out += "}"
    }
}

/// A string as `JSON.stringify` writes it: `"` and `\` escaped, the short
/// escapes `\b \f \n \r \t`, other control characters as `\u00xx`
/// (lower-case hex), everything else verbatim.
private func appendQuoted(_ s: String, to out: inout String) {
    out += "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

/// ECMAScript `Number.prototype.toString()` of a finite double (the RFC 8785
/// number form). Throws for NaN and ±Infinity.
public func ecmaScriptNumberString(_ value: Double) throws -> String {
    try ecmaScriptNumberString(value, path: "$")
}

private func ecmaScriptNumberString(_ value: Double, path: String) throws -> String {
    guard value.isFinite else {
        throw CanonicalJSONError(path: path, reason: "non-finite number (\(value))")
    }
    if value == 0 { return "0" }  // also -0

    // Swift's description is the shortest decimal that round-trips (the same
    // digits ECMAScript chooses); only the layout differs. Split it into its
    // significant digits and the decimal exponent n of ES Number::toString,
    // where value = 0.d1d2…dk × 10^n.
    let text = value.magnitude.description
    var mantissa = Substring(text)
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = text[..<e]
        exponent = Int(text[text.index(after: e)...])!
    }
    var digits = ""
    var pointPosition: Int?
    for ch in mantissa {
        if ch == "." { pointPosition = digits.count } else { digits.append(ch) }
    }
    var n = (pointPosition ?? digits.count) + exponent
    while digits.first == "0" {
        digits.removeFirst()
        n -= 1
    }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count

    var body: String
    if k <= n && n <= 21 {
        body = digits + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        let split = digits.index(digits.startIndex, offsetBy: n)
        body = digits[..<split] + "." + digits[split...]
    } else if -6 < n && n <= 0 {
        body = "0." + String(repeating: "0", count: -n) + digits
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let first = digits.prefix(1)
        let rest = digits.dropFirst()
        body = rest.isEmpty ? "\(first)e\(sign)\(abs(e))" : "\(first).\(rest)e\(sign)\(abs(e))"
    }
    return value < 0 ? "-" + body : body
}

// MARK: - Pretty JSON

/// Indented JSON (two spaces, as `JSON.stringify(value, null, 2)` writes
/// it) with members sorted by their names' UTF-16 code units, strings and
/// numbers in their canonical (RFC 8785) forms, and a trailing newline. The
/// same value always gives the same bytes. Throws for non-finite numbers.
public func prettyJSON(_ value: AnyCodableValue) throws -> String {
    var out = ""
    try appendPretty(value, indent: "", path: "$", to: &out)
    out += "\n"
    return out
}

private func appendPretty(_ value: AnyCodableValue, indent: String, path: String, to out: inout String) throws {
    let inner = indent + "  "
    switch value {
    case .array(let items) where !items.isEmpty:
        out += "[\n"
        for (i, item) in items.enumerated() {
            out += inner
            try appendPretty(item, indent: inner, path: "\(path)[\(i)]", to: &out)
            out += i == items.count - 1 ? "\n" : ",\n"
        }
        out += indent + "]"
    case .dict(let object) where !object.isEmpty:
        out += "{\n"
        let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for (i, key) in keys.enumerated() {
            out += inner + (try canonicalJSON(.string(key))) + ": "
            try appendPretty(object[key]!, indent: inner, path: "\(path).\(key)", to: &out)
            out += i == keys.count - 1 ? "\n" : ",\n"
        }
        out += indent + "}"
    default:
        out += try canonicalJSON(value)
    }
}
