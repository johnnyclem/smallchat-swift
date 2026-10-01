// MARK: - MCPToolkit — load a toolkit and build a runtime whose tools really run

import Foundation
import SmallChatCore
import SmallChatRuntime
import SmallChatCompiler
import SmallChatEmbedding

// MARK: - Endpoint-backed tool

/// Why a tool cannot run.
public struct MCPToolUnavailableError: Error, Sendable, CustomStringConvertible {
    public let toolId: String
    public let reason: String

    public var description: String { "\(toolId) cannot run: \(reason)" }
}

/// A tool implementation that calls the upstream tool at its provider's
/// endpoint: MCP tools over Streamable HTTP (`tools/call`), REST tools as
/// `POST <endpoint>/<toolName>`. A tool whose provider declares no endpoint,
/// or whose transport is not supported here, throws `MCPToolUnavailableError`
/// instead of pretending to run.
public final class EndpointToolIMP: ToolIMP {
    public let providerId: String
    public let toolName: String
    public let transportType: TransportType
    public let schema: ToolSchema?
    /// Why `execute` cannot reach the tool (nil when it can).
    public let unavailableReason: String?
    private let client: MCPClientTransport?

    public init(entry: DispatchEntry, client: MCPClientTransport?) {
        self.providerId = entry.providerId
        self.toolName = entry.toolName
        let transportType = TransportType(rawValue: entry.transportType) ?? .mcp
        self.transportType = transportType
        self.schema = ToolSchema(
            name: entry.toolName,
            description: entry.description ?? "",
            inputSchema: Self.schemaType(entry.inputSchema)
        )
        switch (transportType, entry.endpoint) {
        case (_, nil):
            self.client = nil
            self.unavailableReason = "provider \(entry.providerId) declares no endpoint"
        case (.mcp, let endpoint?) where endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://"):
            self.client = client
            self.unavailableReason = client == nil ? "no client for \(endpoint)" : nil
        case (.rest, _):
            self.client = client
            self.unavailableReason = client == nil ? "no client for the REST endpoint" : nil
        case (_, let endpoint?):
            self.client = nil
            self.unavailableReason = "\(transportType.rawValue) endpoint \(endpoint) is not supported by smallchat serve"
        }
    }

    /// Whether `execute` can reach the tool.
    public var isExecutable: Bool { unavailableReason == nil }

    public func loadSchema() async throws -> ToolSchema {
        guard let schema else {
            throw MCPToolUnavailableError(toolId: "\(providerId)/\(toolName)", reason: "no schema")
        }
        return schema
    }

    public func execute(args: [String: any Sendable]) async throws -> ToolResult {
        guard let client, unavailableReason == nil else {
            throw MCPToolUnavailableError(toolId: "\(providerId)/\(toolName)", reason: unavailableReason ?? "unavailable")
        }
        var arguments: [String: AnyCodableValue] = [:]
        for (key, value) in args {
            guard let converted = anyCodableValue(from: value) else {
                throw MCPToolUnavailableError(toolId: "\(providerId)/\(toolName)", reason: "argument \(key) is not JSON")
            }
            arguments[key] = converted
        }
        return try await client.execute(toolName: toolName, args: arguments)
    }

    private static func schemaType(_ schema: [String: AnyCodableValue]?) -> JSONSchemaType {
        guard let schema,
              let data = try? JSONEncoder().encode(schema),
              let decoded = try? JSONDecoder().decode(JSONSchemaType.self, from: data) else {
            return JSONSchemaType(type: "object")
        }
        return decoded
    }
}

// MARK: - Toolkit

/// A loaded toolkit: the artifact the server lists and a runtime whose tools
/// execute through their providers' endpoints.
public struct MCPToolkit: Sendable {
    public let artifact: SerializedArtifact
    public let runtime: ToolRuntime
    /// Canonical ids (`<providerId>/<toolName>`) of tools that are listed but
    /// cannot run, with the reason.
    public let unavailable: [MCPSkippedTool]

    /// Load a toolkit from `source`: a directory of provider manifests (found
    /// recursively), one manifest file, or a compiled artifact.
    ///
    /// Manifests are compiled with the local embedder. A compiled artifact
    /// carries each provider's endpoint only when it was compiled by 1.0 or
    /// later; tools from older artifacts are listed but cannot run.
    public static func load(source: String, options: RuntimeOptions = RuntimeOptions()) async throws -> MCPToolkit {
        let artifact = try await loadArtifact(source: source)
        return try await make(artifact: artifact, options: options)
    }

    /// Build the runtime for `artifact`: one `ToolClass` per provider holding
    /// an `EndpointToolIMP` per tool, and the artifact's selector vectors
    /// interned for semantic dispatch.
    public static func make(
        artifact: SerializedArtifact,
        embedder: any Embedder = LocalEmbedder(),
        vectorIndex: any VectorIndex = MemoryVectorIndex(),
        options: RuntimeOptions = RuntimeOptions()
    ) async throws -> MCPToolkit {
        let runtime = ToolRuntime(vectorIndex: vectorIndex, embedder: embedder, options: options)

        var clients: [String: MCPClientTransport] = [:]
        var unavailable: [MCPSkippedTool] = []
        for providerId in artifact.dispatchTables.keys.sorted() {
            let methods = artifact.dispatchTables[providerId] ?? [:]
            let toolClass = ToolClass(name: providerId)
            for canonical in methods.keys.sorted() {
                guard let entry = methods[canonical] else { continue }
                var client: MCPClientTransport?
                if let endpoint = entry.endpoint, let type = TransportType(rawValue: entry.transportType),
                   type == .mcp || type == .rest {
                    let key = "\(entry.providerId)|\(endpoint)"
                    client = clients[key] ?? MCPClientTransport(options: MCPTransportOptions(transportType: type, endpoint: endpoint))
                    clients[key] = client
                }
                let imp = EndpointToolIMP(entry: entry, client: client)
                if let reason = imp.unavailableReason {
                    unavailable.append(MCPSkippedTool(toolId: "\(entry.providerId)/\(entry.toolName)", reason: reason))
                }

                let selector: ToolSelector
                if let data = artifact.selectors[canonical], !data.vector.isEmpty {
                    selector = try await runtime.selectorTable.intern(embedding: data.vector, canonical: canonical)
                } else {
                    let parts = canonical.split(separator: ":").map(String.init)
                    selector = ToolSelector(vector: [], canonical: canonical, parts: parts, arity: max(0, parts.count - 1))
                }
                toolClass.addMethod(selector, imp: imp)
            }
            try await runtime.registerClass(toolClass)
        }

        return MCPToolkit(artifact: artifact, runtime: runtime, unavailable: unavailable)
    }

    /// Read `source` as a compiled artifact or as provider manifest(s).
    public static func loadArtifact(source: String) async throws -> SerializedArtifact {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw MCPToolkitError.notFound(source)
        }
        if isDirectory.boolValue {
            return try await compile(manifests: findManifests(in: source), source: source)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        if let artifact = try? JSONDecoder().decode(SerializedArtifact.self, from: data) {
            return artifact
        }
        if let manifest = try? JSONDecoder().decode(ProviderManifest.self, from: data) {
            return try await compile(manifests: [manifest], source: source)
        }
        throw MCPToolkitError.unreadable(source)
    }

    /// Every valid provider manifest under `directory`, recursively.
    public static func findManifests(in directory: String) -> [ProviderManifest] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var manifests: [ProviderManifest] = []
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".json") else { continue }
            let path = (directory as NSString).appendingPathComponent(file)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let manifest = try? JSONDecoder().decode(ProviderManifest.self, from: data) {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.id < $1.id }
    }

    private static func compile(manifests: [ProviderManifest], source: String) async throws -> SerializedArtifact {
        guard !manifests.isEmpty else { throw MCPToolkitError.noManifests(source) }
        let compiler = ToolCompiler(embedder: LocalEmbedder(), vectorIndex: MemoryVectorIndex())
        let result = try await compiler.compile(manifests)
        return buildArtifact(result: result, manifests: manifests)
    }
}

/// Errors loading a toolkit.
public enum MCPToolkitError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case unreadable(String)
    case noManifests(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "No such file or directory: \(path)"
        case .unreadable(let path): return "\(path) is neither a compiled artifact nor a provider manifest"
        case .noManifests(let path): return "No provider manifests found in \(path)"
        }
    }
}
