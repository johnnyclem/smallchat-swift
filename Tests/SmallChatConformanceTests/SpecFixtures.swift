import Foundation
import Testing
import SmallChatCore

/// The @smallchat/core spec copied into Tests/Fixtures/spec by
/// Scripts/sync-spec.sh (see Tests/Fixtures/spec/SOURCE for its commit).
enum SpecFixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/spec")

    static func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func text(_ path: String) throws -> String {
        try String(decoding: data(path), as: UTF8.self)
    }

    /// A fixture parsed with the suite's JSON reader (numbers as ECMAScript
    /// reads them). Lone surrogates, which some negative vectors contain and
    /// a Swift String cannot hold, read as U+FFFD.
    static func json(_ path: String) throws -> AnyCodableValue {
        try parseJSON(data(path), loneSurrogates: .replace)
    }
}

extension AnyCodableValue {
    subscript(key: String) -> AnyCodableValue? {
        if case .dict(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [AnyCodableValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Parameterized vector tests are named after the vector, not its whole JSON.
extension AnyCodableValue: CustomTestStringConvertible {
    public var testDescription: String {
        if let name = self["name"]?.stringValue { return name }
        if let id = self["id"]?.stringValue { return id }
        if let input = self["input"]?.doubleValue { return "\(input)" }
        if let score = self["score"]?.doubleValue { return "\(score)" }
        if let file = self["file"]?.stringValue { return file }
        if let field = self["field"]?.stringValue { return field }
        return "vector"
    }
}
