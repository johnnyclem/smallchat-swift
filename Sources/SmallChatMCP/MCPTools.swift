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
    public let title: String?
    public let outputSchema: [String: AnyCodableValue]?
    public let annotations: ToolAnnotations?

    public init(
        name: String,
        providerId: String,
        toolName: String,
        description: String?,
        inputSchema: [String: AnyCodableValue]?,
        title: String? = nil,
        outputSchema: [String: AnyCodableValue]? = nil,
        annotations: ToolAnnotations? = nil
    ) {
        self.name = name
        self.providerId = providerId
        self.toolName = toolName
        self.description = description
        self.inputSchema = inputSchema
        self.title = title
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    /// Canonical tool id: `<providerId>/<toolName>`.
    public var toolId: String { "\(providerId)/\(toolName)" }

    /// The `tools/list` entry.
    public var listEntry: [String: AnyCodableValue] {
        var entry: [String: AnyCodableValue] = [
            "name": .string(name),
            "inputSchema": .dict(inputSchema ?? ["type": .string("object")]),
        ]
        if let description { entry["description"] = .string(description) }
        if let title { entry["title"] = .string(title) }
        if let outputSchema { entry["outputSchema"] = .dict(outputSchema) }
        if let annotations, !annotations.isEmpty { entry["annotations"] = .dict(annotations.jsonValue) }
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

    public init(artifact: ArtifactV1, naming: MCPToolNaming = .aggregate) {
        self.naming = naming

        var entries: [String: ArtifactTool] = [:]
        for (toolId, tool) in artifact.tools {
            if case .provider(let id) = naming, tool.providerId != id { continue }
            entries[toolId] = tool
        }

        var skipped: [MCPSkippedTool] = []
        var candidates: [String: [MCPExposedTool]] = [:]
        for (toolId, entry) in entries {
            let name: String
            switch naming {
            case .aggregate:
                guard isAggregateProviderId(entry.providerId) else {
                    skipped.append(MCPSkippedTool(toolId: toolId, reason: "provider id \"\(entry.providerId)\" must match [A-Za-z0-9_-], contain no \"__\" and not end in \"_\" to prefix aggregate names; serve it with --provider \(entry.providerId)"))
                    continue
                }
                guard let aggregate = mcpAggregateName(providerId: entry.providerId, toolName: entry.name) else {
                    let candidate = entry.providerId + Self.aggregateSeparator + entry.name
                    skipped.append(MCPSkippedTool(toolId: toolId, reason: "\"\(candidate)\" is not a valid aggregate tool name (^[A-Za-z0-9_-]{1,128}$); serve it with --provider \(entry.providerId)"))
                    continue
                }
                name = aggregate
            case .provider:
                name = entry.name
                guard !name.isEmpty else {
                    skipped.append(MCPSkippedTool(toolId: toolId, reason: "empty tool name"))
                    continue
                }
            }
            candidates[name, default: []].append(MCPExposedTool(
                name: name,
                providerId: entry.providerId,
                toolName: entry.name,
                description: entry.description,
                inputSchema: entry.inputSchema,
                title: entry.title,
                outputSchema: entry.outputSchema,
                annotations: entry.annotations
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
        isValidMCPToolName(name)
    }
}

// MARK: - Execution hooks

/// Runs exactly one listed tool. Throwing reports a tool execution error
/// (`isError: true`) to the client.
public typealias MCPToolExecutor = @Sendable (
    _ tool: MCPExposedTool,
    _ arguments: [String: AnyCodableValue]
) async throws -> ToolResult

/// Resolves an intent to a tool without running anything (the
/// `smallchat_resolve` meta-tool). `arguments` are the call arguments the
/// client intends to pass, when known (used to choose among overloads).
public typealias MCPResolveHandler = @Sendable (
    _ intent: String,
    _ arguments: [String: AnyCodableValue]?
) async throws -> Resolution

/// The read-only meta-tool for semantic resolution. It proposes a tool and
/// returns its MCP name; it never executes anything. `tools/call` on any
/// other name runs exactly that tool. (@smallchat/core 1.0 serves the same
/// tool; smallchat-swift 0.6's executing `smallchat_dispatch` is gone.)
public enum MCPResolveTool {
    public static let name = "smallchat_resolve"

    public static var listEntry: [String: AnyCodableValue] {
        [
            "name": .string(name),
            "title": .string("Resolve an intent to a tool"),
            "description": .string(
                "Propose the tool on this server that matches a natural-language intent. Returns the tool name, "
                + "canonical id, confidence tier, ranked candidates and a proof digest. It never runs anything: "
                + "call the proposed tool by name to execute it."
            ),
            "inputSchema": .dict([
                "type": .string("object"),
                "properties": .dict([
                    "intent": .dict([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("What you want to do, in plain language"),
                    ]),
                    "args": .dict([
                        "type": .string("object"),
                        "description": .string("The arguments you intend to pass, if known (used to choose among overloads)"),
                    ]),
                ]),
                "required": .array([.string("intent")]),
                "additionalProperties": .bool(false),
            ]),
        ]
    }
}

/// `_meta` key of the compact resolution summary every result carries.
public let mcpResolutionMetaKey = "dev.smallchat/resolution"

/// The compact, digest-bound summary of a proof (`_meta["dev.smallchat/resolution"]`).
public func compactResolution(_ proof: ResolutionProof) -> AnyCodableValue {
    func optional(_ s: String?) -> AnyCodableValue { s.map { .string($0) } ?? .null }
    return .dict([
        "toolId": optional(proof.chosen),
        "ran": optional(proof.ran),
        "outcome": .string(proof.outcome.rawValue),
        "decision": .string(proof.decision.rawValue),
        "tier": .string(proof.tier.rawValue),
        "callDigest": optional(proof.callDigest),
        "proofDigest": .string(proof.proofDigest),
        "artifactHash": optional(proof.artifactHash),
    ])
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
    } else if result.isError {
        shaped = [
            "content": .array([.dict(["type": .string("text"), "text": .string(errorText(result.content))])]),
            "isError": .bool(true),
        ]
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
    var meta = meta
    if let proof = result.metadata?["proof"] as? ResolutionProof {
        meta[mcpResolutionMetaKey] = compactResolution(proof)
    }
    if !meta.isEmpty {
        var existing: [String: AnyCodableValue] = [:]
        if case .dict(let current)? = shaped["_meta"] { existing = current }
        shaped["_meta"] = .dict(existing.merging(meta) { _, new in new })
    }
    return .dict(shaped)
}

/// The text of an error result: its `error` line and each of its `errors`.
func errorText(_ content: (any Sendable)?) -> String {
    let value = (content as? AnyCodableValue) ?? content.flatMap { anyCodableValue(from: $0) }
    if case .dict(var object)? = value, case .string(let error)? = object["error"] {
        object.removeValue(forKey: "error")
        var lines = [error]
        if case .array(let errors)? = object.removeValue(forKey: "errors") {
            lines += errors.map { if case .string(let e) = $0 { return "- \(e)" }; return "- \(jsonText($0))" }
        }
        if !object.isEmpty { lines.append(jsonText(.dict(object))) }
        return lines.joined(separator: "\n")
    }
    return contentText(content)
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
