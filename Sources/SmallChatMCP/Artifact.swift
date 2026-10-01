// MARK: - Artifact — Compiled tool artifact serialization

import Foundation
import SmallChatCore

/// The compiled-artifact format version emitted by this implementation. Matches
/// the TypeScript reference (`src/mcp/artifact.ts`) so that artifacts compiled by
/// either runtime are interchangeable. Loading is version-agnostic (older 0.1.0 /
/// 0.3.0 artifacts still decode).
public let ARTIFACT_FORMAT_VERSION = "0.5.0"

// MARK: - Serialized Artifact

/// A compiled tool artifact that can be saved to and loaded from disk.
///
/// Contains the full state needed to hydrate a ToolRuntime:
/// selectors with their embedding vectors and dispatch tables
/// mapping providers to tool implementations.
public struct SerializedArtifact: Sendable, Codable {
    /// Artifact format version. We *write* `ARTIFACT_FORMAT_VERSION` ("0.5.0") to
    /// match the TypeScript `@smallchat/core` artifact ABI, and *read* any version
    /// (Codable does not constrain this field), preserving backward compatibility
    /// with older 0.1.0/0.3.0 artifacts.
    public let version: String
    public let stats: ArtifactStats
    public let selectors: [String: SelectorData]
    public let dispatchTables: [String: [String: DispatchEntry]]

    public init(
        version: String = ARTIFACT_FORMAT_VERSION,
        stats: ArtifactStats,
        selectors: [String: SelectorData],
        dispatchTables: [String: [String: DispatchEntry]]
    ) {
        self.version = version
        self.stats = stats
        self.selectors = selectors
        self.dispatchTables = dispatchTables
    }
}

/// Summary statistics for a compiled artifact.
public struct ArtifactStats: Sendable, Codable {
    public let toolCount: Int
    public let uniqueSelectorCount: Int
    public let providerCount: Int
    public let collisionCount: Int

    public init(
        toolCount: Int,
        uniqueSelectorCount: Int,
        providerCount: Int,
        collisionCount: Int
    ) {
        self.toolCount = toolCount
        self.uniqueSelectorCount = uniqueSelectorCount
        self.providerCount = providerCount
        self.collisionCount = collisionCount
    }
}

/// Serialized selector with its embedding vector and metadata.
public struct SelectorData: Sendable, Codable {
    public let canonical: String
    public let parts: [String]
    public let arity: Int
    public let vector: [Float]

    public init(canonical: String, parts: [String], arity: Int, vector: [Float]) {
        self.canonical = canonical
        self.parts = parts
        self.arity = arity
        self.vector = vector
    }
}

/// A single entry in a dispatch table mapping a selector to a tool implementation.
public struct DispatchEntry: Sendable, Codable {
    public let providerId: String
    public let toolName: String
    public let transportType: String
    public let inputSchema: [String: AnyCodableValue]?
    /// The upstream tool description (absent in artifacts compiled before 1.0).
    public let description: String?
    /// Where the provider is reached (its manifest `endpoint`): an MCP
    /// Streamable HTTP URL for `mcp`, a base URL for `rest`. Absent when the
    /// manifest declares none; such tools are listed but cannot run.
    public let endpoint: String?

    public init(
        providerId: String,
        toolName: String,
        transportType: String,
        inputSchema: [String: AnyCodableValue]? = nil,
        description: String? = nil,
        endpoint: String? = nil
    ) {
        self.providerId = providerId
        self.toolName = toolName
        self.transportType = transportType
        self.inputSchema = inputSchema
        self.description = description
        self.endpoint = endpoint
    }
}

// MARK: - Artifact Persistence

/// Save and load compiled artifacts from disk.
public enum ArtifactIO {

    /// Save an artifact to a JSON file.
    public static func save(_ artifact: SerializedArtifact, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
    }

    /// Load an artifact from a JSON file.
    public static func load(from path: String) throws -> SerializedArtifact {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SerializedArtifact.self, from: data)
    }
}

// MARK: - Tool List Builder

/// Build the MCP `tools/list` entries for a serialized artifact, named as in
/// aggregate mode (`<providerId>__<toolName>`). See `MCPToolCatalog`.
public func buildToolList(_ artifact: SerializedArtifact) -> [[String: AnyCodableValue]] {
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

// MARK: - Artifact Builder

/// Build a SerializedArtifact from a CompilationResult and manifests.
public func buildArtifact(
    result: CompilationResult,
    manifests: [ProviderManifest]
) -> SerializedArtifact {
    // Index each tool's schema and description, and each provider's
    // endpoint, by provider: two providers may share a tool name.
    var schemaIndex: [String: [String: AnyCodableValue]] = [:]
    var descriptionIndex: [String: String] = [:]
    var endpointIndex: [String: String] = [:]
    for manifest in manifests {
        if let endpoint = manifest.endpoint { endpointIndex[manifest.id] = endpoint }
        for tool in manifest.tools {
            let key = "\(manifest.id)/\(tool.name)"
            descriptionIndex[key] = tool.description
            // Convert JSONSchemaType to AnyCodableValue dict
            if let data = try? JSONEncoder().encode(tool.inputSchema),
               let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) {
                schemaIndex[key] = dict
            }
        }
    }

    // Build selectors
    var selectors: [String: SelectorData] = [:]
    for (key, sel) in result.selectors {
        selectors[key] = SelectorData(
            canonical: sel.canonical,
            parts: sel.parts,
            arity: sel.arity,
            vector: Array(sel.vector)
        )
    }

    // Build dispatch tables
    var dispatchTables: [String: [String: DispatchEntry]] = [:]
    for (providerId, table) in result.dispatchTables {
        var methods: [String: DispatchEntry] = [:]
        for (canonical, imp) in table {
            let key = "\(imp.providerId)/\(imp.toolName)"
            methods[canonical] = DispatchEntry(
                providerId: imp.providerId,
                toolName: imp.toolName,
                transportType: imp.transportType.rawValue,
                inputSchema: schemaIndex[key],
                description: descriptionIndex[key],
                endpoint: endpointIndex[imp.providerId]
            )
        }
        dispatchTables[providerId] = methods
    }

    return SerializedArtifact(
        version: ARTIFACT_FORMAT_VERSION,
        stats: ArtifactStats(
            toolCount: result.toolCount,
            uniqueSelectorCount: result.uniqueSelectorCount,
            providerCount: result.dispatchTables.count,
            collisionCount: result.collisions.count
        ),
        selectors: selectors,
        dispatchTables: dispatchTables
    )
}
