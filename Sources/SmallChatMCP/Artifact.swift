// MARK: - Artifact — Compiled tool artifact serialization

import Foundation
import SmallChatCore

// Compiled artifacts are format 1.0 (`ArtifactV1` and
// `ARTIFACT_FORMAT_VERSION` in SmallChatCore, spec/artifact in
// @smallchat/core): `ArtifactV1.read(contentsOf:)` validates one,
// `ArtifactV1.build(result:manifests:embedder:)` writes one.

// MARK: - Tool List Builder

/// Build the MCP `tools/list` entries for an artifact, named as in
/// aggregate mode (`<providerId>__<toolName>`). See `MCPToolCatalog`.
public func buildToolList(_ artifact: ArtifactV1) -> [[String: AnyCodableValue]] {
    MCPToolCatalog(artifact: artifact).tools.map { $0.listEntry }
}

/// Format a ToolResult's content as MCP content blocks: a string is one text
/// block; anything else is one text block holding its JSON.
public func formatContent(_ result: ToolResult) -> [[String: AnyCodableValue]] {
    [["type": .string("text"), "text": .string(contentText(result.content))]]
}

/// The text form of a tool result's content: strings verbatim, JSON values
/// as compact JSON, anything else described.
func contentText(_ content: (any Sendable)?) -> String {
    switch content {
    case nil:
        return ""
    case let text as String:
        return text
    case .string(let text) as AnyCodableValue:
        return text
    case let value as AnyCodableValue:
        return jsonText(value)
    case let some?:
        if let value = anyCodableValue(from: some) {
            return jsonText(value)
        }
        return String(describing: some)
    }
}

/// Compact, key-sorted JSON for a value.
func jsonText(_ value: AnyCodableValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// Convert a Foundation JSON value (from `JSONSerialization`, or plain Swift
/// scalars, arrays and dictionaries) to an `AnyCodableValue`. Returns nil for
/// anything that is not JSON.
func anyCodableValue(from value: Any) -> AnyCodableValue? {
    // Exact type checks: on Apple platforms `as? Bool` and `as? Int` both
    // match an NSNumber (and each other), so test what the value really is.
    let valueType = type(of: value)
    if valueType == Bool.self { return .bool(value as! Bool) }
    if valueType == Int.self { return .int(value as! Int) }
    if valueType == Double.self { return .double(value as! Double) }
    if valueType == Float.self { return .double(Double(value as! Float)) }
    if let codable = value as? AnyCodableValue { return codable }
    if let string = value as? String { return .string(string) }
    if value is NSNull { return .null }
    if valueType is NSNumber.Type, let number = value as? NSNumber {
        switch String(cString: number.objCType) {
        case "c": return .bool(number.boolValue)
        case "f", "d": return .double(number.doubleValue)
        default: return .int(number.intValue)
        }
    }
    if let array = value as? [Any] {
        var items: [AnyCodableValue] = []
        for item in array {
            guard let converted = anyCodableValue(from: item) else { return nil }
            items.append(converted)
        }
        return .array(items)
    }
    if let dict = value as? [String: Any] {
        var out: [String: AnyCodableValue] = [:]
        for (key, item) in dict {
            guard let converted = anyCodableValue(from: item) else { return nil }
            out[key] = converted
        }
        return .dict(out)
    }
    return nil
}
