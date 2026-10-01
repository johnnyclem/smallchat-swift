// MARK: - MCPTools — the tools the server lists, and how a call's result is shaped

import Foundation
import SmallChatCore
import SmallChatRuntime

// MARK: - Naming

/// How the server names tools on the MCP surface (suite contract: canonical
/// tool id `<providerId>/<toolName>`).
public enum MCPToolNaming: Sendable, Equatable {
    /// Every provider's tools, named `<providerId>__<toolName>`. Names must
    /// match `^[A-Za-z0-9_-]{1,128}$`; a tool whose name cannot be written that
    /// way is left out (and reported), never renamed.
    case aggregate
    /// One provider's tools under their upstream names, verbatim (so policies
    /// keyed on upstream names apply unchanged).
    case provider(String)
}

/// One tool as the MCP server lists and calls it.
public struct MCPExposedTool: Sendable, Equatable {
    /// The name in `tools/list`, and the only name `tools/call` accepts.
    public let name: String
    public let providerId: String
    public let toolName: String
    public let description: String?
    public let inputSchema: [String: AnyCodableValue]?

    /// Canonical tool id: `<providerId>/<toolName>`.
    public var toolId: String { "\(providerId)/\(toolName)" }

    /// The `tools/list` entry.
    public var listEntry: [String: AnyCodableValue] {
        var entry: [String: AnyCodableValue] = [
            "name": .string(name),
            "inputSchema": .dict(inputSchema ?? ["type": .string("object")]),
        ]
        if let description { entry["description"] = .string(description) }
        return entry
    }
}

/// A tool the catalog could not list, and why.
public struct MCPSkippedTool: Sendable, Equatable {
    public let toolId: String
    public let reason: String
}

/// The tools of an artifact as the MCP server exposes them: exact names, a
/// stable order, and nothing guessed.
public struct MCPToolCatalog: Sendable {
    public let naming: MCPToolNaming
    /// Listed tools, sorted by name.
    public let tools: [MCPExposedTool]
    /// Tools left out because their name is not a valid MCP tool name or
    /// collides with another tool's.
    public let skipped: [MCPSkippedTool]
    private let byName: [String: MCPExposedTool]

    public static let aggregateSeparator = "__"

    public init(artifact: SerializedArtifact, naming: MCPToolNaming = .aggregate) {
        self.naming = naming

        // One entry per tool, even if several selectors point at it.
        var entries: [String: DispatchEntry] = [:]
        for providerKey in artifact.dispatchTables.keys.sorted() {
            let methods = artifact.dispatchTables[providerKey] ?? [:]
            for canonical in methods.keys.sorted() {
                guard let entry = methods[canonical] else { continue }
                if case .provider(let id) = naming, entry.providerId != id { continue }
                let toolId = "\(entry.providerId)/\(entry.toolName)"
                if entries[toolId] == nil { entries[toolId] = entry }
            }
        }

        var skipped: [MCPSkippedTool] = []
        var candidates: [String: [MCPExposedTool]] = [:]
        for (toolId, entry) in entries {
            let name: String
            switch naming {
            case .aggregate:
                name = entry.providerId + Self.aggregateSeparator + entry.toolName
                guard Self.isValidAggregateName(name) else {
                    skipped.append(MCPSkippedTool(toolId: toolId, reason: "\"\(name)\" is not a valid MCP tool name (^[A-Za-z0-9_-]{1,128}$)"))
                    continue
                }
            case .provider:
                name = entry.toolName
                guard !name.isEmpty else {
                    skipped.append(MCPSkippedTool(toolId: toolId, reason: "empty tool name"))
                    continue
                }
            }
            candidates[name, default: []].append(MCPExposedTool(
                name: name,
                providerId: entry.providerId,
                toolName: entry.toolName,
                description: entry.description,
                inputSchema: entry.inputSchema
            ))
        }

        var byName: [String: MCPExposedTool] = [:]
        for (name, tools) in candidates {
            if tools.count == 1 {
                byName[name] = tools[0]
            } else {
                let ids = tools.map(\.toolId).sorted()
                for tool in tools {
                    skipped.append(MCPSkippedTool(toolId: tool.toolId, reason: "name \"\(name)\" is shared by \(ids.joined(separator: ", "))"))
                }
            }
        }

        self.byName = byName
        self.tools = byName.values.sorted { $0.name < $1.name }
        self.skipped = skipped.sorted { $0.toolId < $1.toolId }
    }

    /// The tool listed under exactly `name`, if any.
    public func tool(named name: String) -> MCPExposedTool? {
        byName[name]
    }

    static func isValidAggregateName(_ name: String) -> Bool {
        guard (1...128).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }
}

// MARK: - Execution hooks

/// Runs exactly one listed tool. Throwing reports a tool execution error
/// (`isError: true`) to the client.
public typealias MCPToolExecutor = @Sendable (
    _ tool: MCPExposedTool,
    _ arguments: [String: AnyCodableValue]
) async throws -> ToolResult

/// Resolves an intent semantically and dispatches it (the opt-in
/// `smallchat_dispatch` meta-tool).
public typealias MCPSemanticDispatchHandler = @Sendable (
    _ intent: String,
    _ arguments: [String: AnyCodableValue]
) async throws -> TieredDispatchResult

/// The explicit meta-tool for semantic dispatch. `tools/call` on any other
/// name runs exactly that tool; only this tool resolves an intent.
public enum MCPSemanticDispatchTool {
    public static let name = "smallchat_dispatch"

    public static var listEntry: [String: AnyCodableValue] {
        [
            "name": .string(name),
            "description": .string(
                "Resolve a natural-language intent to one of this server's tools by semantic similarity "
                + "and run it when the match is confident (EXACT/HIGH tier, or MEDIUM after verification). "
                + "Otherwise nothing runs and the result asks for refinement or lists sub-intents. "
                + "Prefer calling a listed tool by name."
            ),
            "inputSchema": .dict([
                "type": .string("object"),
                "properties": .dict([
                    "intent": .dict([
                        "type": .string("string"),
                        "description": .string("What to do, in natural language."),
                    ]),
                    "arguments": .dict([
                        "type": .string("object"),
                        "description": .string("Arguments for the resolved tool."),
                    ]),
                ]),
                "required": .array([.string("intent")]),
            ]),
        ]
    }
}

// MARK: - Result shaping

/// Metadata key a `ToolResult` carries when its content is already an MCP
/// `CallToolResult` from an upstream server (passed through unchanged).
public let mcpCallToolResultMetadataKey = "mcp.callToolResult"

/// Build the MCP `CallToolResult` (`{content, structuredContent?, isError}`)
/// for a tool's result.
///
/// - An upstream `CallToolResult` (see `mcpCallToolResultMetadataKey`) is
///   passed through.
/// - A JSON object result becomes `structuredContent`, with its JSON also in
///   a text block (as MCP asks, for clients that do not read structured
///   content).
/// - Anything else becomes one text block.
public func mcpCallToolResult(
    _ result: ToolResult,
    meta: [String: AnyCodableValue] = [:]
) -> AnyCodableValue {
    var shaped: [String: AnyCodableValue]
    if result.metadata?[mcpCallToolResultMetadataKey] as? Bool == true,
       let upstream = result.content as? AnyCodableValue,
       case .dict(var dict) = upstream,
       case .array = dict["content"] {
        if dict["isError"] == nil { dict["isError"] = .bool(result.isError) }
        shaped = dict
    } else {
        shaped = [
            "content": .array(formatContent(result).map { .dict($0) }),
            "isError": .bool(result.isError),
        ]
        let value = (result.content as? AnyCodableValue) ?? result.content.flatMap { anyCodableValue(from: $0) }
        if case .dict(let object)? = value {
            shaped["structuredContent"] = .dict(object)
        }
    }
    if !meta.isEmpty {
        var existing: [String: AnyCodableValue] = [:]
        if case .dict(let current)? = shaped["_meta"] { existing = current }
        shaped["_meta"] = .dict(existing.merging(meta) { _, new in new })
    }
    return .dict(shaped)
}

/// A tool execution error as a `CallToolResult` (`isError: true`).
public func mcpErrorResult(_ message: String, meta: [String: AnyCodableValue] = [:]) -> AnyCodableValue {
    var result: [String: AnyCodableValue] = [
        "content": .array([.dict(["type": .string("text"), "text": .string(message)])]),
        "isError": .bool(true),
    ]
    if !meta.isEmpty { result["_meta"] = .dict(meta) }
    return .dict(result)
}

/// A short, readable description of an error for a tool result.
func describeError(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}

/// Encode any `Encodable` value (a proof, a refinement) as an `AnyCodableValue`.
func encodeAsValue<T: Encodable>(_ value: T) -> AnyCodableValue {
    guard let data = try? JSONEncoder().encode(value),
          let decoded = try? JSONDecoder().decode(AnyCodableValue.self, from: data) else {
        return .null
    }
    return decoded
}
