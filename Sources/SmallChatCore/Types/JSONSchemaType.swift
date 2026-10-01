// MARK: - AnyCodableValue

public enum AnyCodableValue: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let d = try? container.decode(Double.self) {
            // Prefer .int when the JSON number has no fractional part and fits
            // in Int, so that plain integers like 42 or 1 decode as .int.
            // Values like 1.5 or numbers outside Int range stay as .double.
            let isInteger = d.truncatingRemainder(dividingBy: 1) == 0
            if isInteger, let i = try? container.decode(Int.self) {
                self = .int(i)
            } else {
                self = .double(d)
            }
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
            return
        }
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "AnyCodableValue cannot decode value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .dict(let dict): try container.encode(dict)
        }
    }
}

// MARK: - Box (indirect wrapper for recursive Codable struct)

@dynamicMemberLookup
public final class Box<T: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public let value: T

    public init(_ value: T) {
        self.value = value
    }

    public subscript<U>(dynamicMember keyPath: KeyPath<T, U>) -> U {
        value[keyPath: keyPath]
    }

    public static func == (lhs: Box<T>, rhs: Box<T>) -> Bool {
        lhs.value == rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - JSONSchemaType

/// A JSON Schema, with the keywords smallchat reads typed (`type`,
/// `description`, `enum`, `items`, `properties`, `required`, `default`)
/// and every other keyword kept verbatim.
///
/// Decoding never drops a keyword: `jsonValue` (and `encode(to:)`) give
/// back the full schema, which is what argument validation and artifact
/// format 1.0 use. A typed field set to a value replaces the decoded
/// keyword; a typed field that is nil (or a `type` that is empty) falls
/// back to the decoded keyword, so a schema whose `type` is an array of
/// types, or whose `items` is a tuple or a boolean schema, survives a
/// round trip. A schema without `type` decodes with `type == ""`.
public struct JSONSchemaType: Sendable, Codable, Equatable {
    public var type: String
    public var description: String?
    public var enumValues: [AnyCodableValue]?
    public var items: Box<JSONSchemaType>?
    public var properties: [String: JSONSchemaType]?
    public var required: [String]?
    public var defaultValue: AnyCodableValue?
    /// Every keyword of the decoded schema, verbatim (empty when the schema
    /// was built in code).
    public var keywords: [String: AnyCodableValue]

    public init(
        type: String,
        description: String? = nil,
        enumValues: [AnyCodableValue]? = nil,
        items: JSONSchemaType? = nil,
        properties: [String: JSONSchemaType]? = nil,
        required: [String]? = nil,
        defaultValue: AnyCodableValue? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items.map { Box($0) }
        self.properties = properties
        self.required = required
        self.defaultValue = defaultValue
        self.keywords = [:]
    }

    /// The schema of a JSON object (as found in a manifest or artifact).
    public init(json object: [String: AnyCodableValue]) {
        keywords = object
        if case .string(let t)? = object["type"] { type = t } else { type = "" }
        if case .string(let d)? = object["description"] { description = d } else { description = nil }
        if case .array(let values)? = object["enum"] { enumValues = values } else { enumValues = nil }
        if case .dict(let item)? = object["items"] { items = Box(JSONSchemaType(json: item)) } else { items = nil }
        if case .dict(let props)? = object["properties"] {
            var typed: [String: JSONSchemaType] = [:]
            for (name, value) in props {
                if case .dict(let schema) = value { typed[name] = JSONSchemaType(json: schema) }
            }
            properties = typed
        } else {
            properties = nil
        }
        if case .array(let names)? = object["required"] {
            required = names.compactMap { if case .string(let n) = $0 { return n } else { return nil } }
        } else {
            required = nil
        }
        defaultValue = object["default"]
    }

    /// The full schema as a JSON object (see the type's documentation).
    public var jsonValue: [String: AnyCodableValue] {
        var object = keywords
        if !type.isEmpty { object["type"] = .string(type) }
        if let description { object["description"] = .string(description) }
        if let enumValues { object["enum"] = .array(enumValues) }
        if let items { object["items"] = .dict(items.value.jsonValue) }
        if let properties {
            var props: [String: AnyCodableValue] = [:]
            if case .dict(let decoded)? = keywords["properties"] { props = decoded }
            for (name, schema) in properties { props[name] = .dict(schema.jsonValue) }
            object["properties"] = .dict(props)
        }
        if let required { object["required"] = .array(required.map { .string($0) }) }
        if let defaultValue { object["default"] = defaultValue }
        return object
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(json: try container.decode([String: AnyCodableValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    /// Two schemas are equal when they are the same JSON Schema.
    public static func == (lhs: JSONSchemaType, rhs: JSONSchemaType) -> Bool {
        lhs.jsonValue == rhs.jsonValue
    }
}
