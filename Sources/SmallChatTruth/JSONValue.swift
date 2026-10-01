import Foundation
import SmallChatCore

// MARK: - JSONValue
//
// Minimal JSON tree for the fields SmallChatTruth does not interpret — the
// stenographer-namespaced `x-steno` key and fields a newer writer added.
// They are kept as read; an entry read from a stream is written back as the
// exact line it came from, so they never pass through this type on the way
// out.

public indirect enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode integral numbers without a trailing ".0" so common
            // values (line numbers, scores) survive the round trip textually.
            if value.rounded() == value, value.magnitude < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// A value read by SmallChatCore's JSON reader (numbers as ECMAScript reads them).
    public init(_ value: AnyCodableValue) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .number(Double(i))
        case .double(let d): self = .number(d)
        case .string(let s): self = .string(s)
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .dict(let object): self = .object(object.mapValues(JSONValue.init))
        }
    }

    /// The same value for SmallChatCore's canonical JSON (RFC 8785).
    public var anyCodableValue: AnyCodableValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d):
            if d.rounded() == d, d.magnitude <= 9_007_199_254_740_992, !(d == 0 && d.sign == .minus) {
                return .int(Int(d))
            }
            return .double(d)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(\.anyCodableValue))
        case .object(let object): return .dict(object.mapValues(\.anyCodableValue))
        }
    }
}
