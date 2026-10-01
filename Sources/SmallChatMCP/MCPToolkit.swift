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
/// remote launch URL: MCP tools over Streamable HTTP (`tools/call`), REST
/// tools as `POST <url>/<toolName>`. A tool whose provider has no remote
/// launch URL (none, or a stdio command, which `serve` does not start), or
/// whose transport is not supported here, throws `MCPToolUnavailableError`
/// instead of pretending to run.
public final class EndpointToolIMP: ToolIMP {
    public let providerId: String
    public let toolName: String
    public let transportType: TransportType
    public let schema: ToolSchema?
    public let annotations: ToolAnnotations?
    /// Why `execute` cannot reach the tool (nil when it can).
    public let unavailableReason: String?
    private let client: MCPClientTransport?

    public init(tool: ArtifactTool, provider: ArtifactProvider?, client: MCPClientTransport?) {
        self.providerId = tool.providerId
        self.toolName = tool.name
        let transportType = TransportType(rawValue: tool.transportType) ?? .mcp
        self.transportType = transportType
        self.schema = ToolSchema(
            name: tool.name,
            description: tool.description,
            inputSchema: JSONSchemaType(json: tool.inputSchema)
        )
        self.annotations = tool.annotations
        let url = Self.remoteURL(provider)
        switch (transportType, provider?.launch, url) {
        case (_, nil, _):
            self.client = nil
            self.unavailableReason = "provider \(tool.providerId) records no launch spec or endpoint"
        case (_, let launch?, nil) where launch.isStdio:
            self.client = nil
            self.unavailableReason = "provider \(tool.providerId) is a stdio server (\(launch.command ?? "?")); smallchat-swift serve runs only HTTP providers"
        case (.mcp, _, let url?) where url.hasPrefix("http://") || url.hasPrefix("https://"):
            self.client = client
            self.unavailableReason = client == nil ? "no client for \(url)" : nil
        case (.rest, _, _?):
            self.client = client
            self.unavailableReason = client == nil ? "no client for the REST endpoint" : nil
        case (_, _, let url):
            self.client = nil
            self.unavailableReason = "\(transportType.rawValue) endpoint \(url ?? "?") is not supported by smallchat serve"
        }
    }

    /// The URL of a provider's remote launch spec, if it has one.
    static func remoteURL(_ provider: ArtifactProvider?) -> String? {
        guard let launch = provider?.launch, !launch.isStdio, let url = launch.url, !url.isEmpty else { return nil }
        return url
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
}

// MARK: - Toolkit

/// A loaded toolkit: the artifact the server lists and a runtime whose tools
/// execute through their providers' endpoints.
public struct MCPToolkit: Sendable {
    public let artifact: ArtifactV1
    public let runtime: ToolRuntime
    /// Canonical ids (`<providerId>/<toolName>`) of tools that are listed but
    /// cannot run, with the reason.
    public let unavailable: [MCPSkippedTool]

    /// Load a toolkit from `source`: a directory of provider manifests (found
    /// recursively), one manifest file, or a compiled artifact (format 1.0;
    /// older artifacts are refused with a request to recompile).
    ///
    /// Manifests are compiled with the hash embedder (`LocalEmbedder`, 384
    /// dimensions). An artifact is used only with the embedder its
    /// fingerprint names: `embedder` when given (it must declare that
    /// fingerprint), else the built-in one (`builtinEmbedder(for:)`).
    public static func load(
        source: String,
        embedder: (any Embedder)? = nil,
        options: RuntimeOptions = RuntimeOptions()
    ) async throws -> MCPToolkit {
        let artifact = try await loadArtifact(source: source)
        return try await make(artifact: artifact, embedder: embedder, options: options)
    }

    /// Build the runtime for `artifact`: one `ToolClass` per provider holding
    /// an `EndpointToolIMP` per tool, reachable through each of the tool's
    /// selectors (primary and aliases), with the artifact's vectors
    /// registered as they are (never merged). Refuses an embedder whose
    /// fingerprint differs from the artifact's (`EmbedderMismatchError`).
    public static func make(
        artifact: ArtifactV1,
        embedder: (any Embedder)? = nil,
        vectorIndex: any VectorIndex = MemoryVectorIndex(),
        options: RuntimeOptions = RuntimeOptions()
    ) async throws -> MCPToolkit {
        let embedder = try embedder ?? builtinEmbedder(for: artifact.embedder)
        try artifact.assertEmbedder(embedder)
        var options = options
        options.artifactHash = artifact.contentHash
        let runtime = ToolRuntime(vectorIndex: vectorIndex, embedder: embedder, options: options)

        var clients: [String: MCPClientTransport] = [:]
        var unavailable: [MCPSkippedTool] = []
        var classes: [String: ToolClass] = [:]
        for toolId in artifact.toolIds {
            guard let tool = artifact.tools[toolId] else { continue }
            let provider = artifact.providers[tool.providerId]
            var client: MCPClientTransport?
            if let url = EndpointToolIMP.remoteURL(provider), let type = TransportType(rawValue: tool.transportType),
               type == .mcp || type == .rest {
                let key = "\(tool.providerId)|\(url)"
                client = clients[key] ?? MCPClientTransport(options: MCPTransportOptions(transportType: type, endpoint: url))
                clients[key] = client
            }
            let imp = EndpointToolIMP(tool: tool, provider: provider, client: client)
            if let reason = imp.unavailableReason {
                unavailable.append(MCPSkippedTool(toolId: toolId, reason: reason))
            }
            let toolClass = classes[tool.providerId] ?? ToolClass(name: tool.providerId)
            classes[tool.providerId] = toolClass
            for selector in artifact.selectors(of: toolId) {
                let registered = try await runtime.selectorTable.register(embedding: selector.vector, canonical: selector.canonical)
                toolClass.addMethod(registered, imp: imp)
            }
        }
        for providerId in classes.keys.sorted() {
            try await runtime.registerClass(classes[providerId]!)
        }

        return MCPToolkit(artifact: artifact, runtime: runtime, unavailable: unavailable)
    }

    /// Read `source` as a compiled artifact or as provider manifest(s).
    public static func loadArtifact(source: String) async throws -> ArtifactV1 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw MCPToolkitError.notFound(source)
        }
        if isDirectory.boolValue {
            return try await compile(manifests: findManifests(in: source), source: source)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        if case .dict(let object)? = try? parseJSON(data),
           object["formatVersion"] != nil || object["version"] != nil || object["dispatchTables"] != nil {
            return try ArtifactV1.validate(.dict(object), source: source)
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

    /// Compile manifests with the hash embedder (384 dimensions) into a 1.0 artifact.
    public static func compile(manifests: [ProviderManifest], source: String = "manifests") async throws -> ArtifactV1 {
        guard !manifests.isEmpty else { throw MCPToolkitError.noManifests(source) }
        let embedder = LocalEmbedder()
        let compiler = ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex())
        let result = try await compiler.compile(manifests)
        return try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
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
