import Foundation
import SmallChatCore

// MARK: - LoomMCPClient
//
// Thin convenience wrapper around `MCPStdioTransport` configured to spawn
// the `muhnehh/loom-mcp` server. Mirrors the runtime-side wiring TS gets
// out of the box once `examples/loom-mcp-manifest.json` is compiled into
// the dispatch table.
//
// Usage:
//
//     let loom = LoomMCPClient()
//     try await loom.connect()
//     let tools = try await loom.listTools()
//     // ... dispatch via the runtime; loom_find_importers, etc.
//     try await loom.disconnect()

public actor LoomMCPClient {

    // MARK: - Provider id used in compiled manifests
    public static let providerId: String = "loom"

    // MARK: - Defaults

    /// Default install command (`npx -y @loom-mcp/server`). Override via
    /// `init(config:)` for `pnpm`, `bunx`, container runtimes, etc.
    public static let defaultCommand: String = "npx"
    public static let defaultArgs: [String] = ["-y", "@loom-mcp/server"]

    /// Suggested env-var override read by the loom server. The TS docs
    /// mention `LOOM_WORKSPACE`; passing the user's project root makes
    /// `loom_index_folder` operate without an explicit `path` argument.
    public static let workspaceEnvVar: String = "LOOM_WORKSPACE"

    // MARK: - Storage

    private let transport: MCPStdioTransport

    public init(workspace: String? = nil, command: String? = nil, args: [String]? = nil) {
        var env: [String: String] = [:]
        if let workspace { env[Self.workspaceEnvVar] = workspace }

        let config = MCPStdioConfig(
            command: command ?? Self.defaultCommand,
            args: args ?? Self.defaultArgs,
            env: env,
            initTimeout: 30
        )
        self.transport = MCPStdioTransport(config: config)
    }

    public init(config: MCPStdioConfig) {
        self.transport = MCPStdioTransport(config: config)
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        try await transport.connect()
    }

    public func disconnect() async throws {
        try await transport.disconnect()
    }

    public var isConnected: Bool {
        get async { await transport.isConnected }
    }

    // MARK: - Discovery

    /// List the tools the live server advertises. The returned dicts are
    /// the raw MCP `tools/list` payloads -- callers typically only need
    /// the names, since the compiled manifest already carries the
    /// schemas.
    public func listTools() async throws -> [[String: Any]] {
        try await transport.listTools()
    }

    /// Names of the tools the live server advertises.
    public func toolNames() async throws -> [String] {
        let tools = try await listTools()
        return tools.compactMap { $0["name"] as? String }
    }

    /// Whether the well-known loom tool set is available on this server.
    /// Returns the names of any tools that are missing relative to the
    /// 0.5.0 bundled manifest.
    public func missingTools() async throws -> [String] {
        let live = Set(try await toolNames())
        return Self.knownToolNames.filter { !live.contains($0) }
    }

    /// Direct call into a tool. Convenience over `transport.execute(...)`
    /// for simple string-typed args.
    public func call(_ tool: String, args: [String: String] = [:]) async throws -> TransportOutput {
        let mappedArgs: [String: AnySendable] = args.reduce(into: [:]) { $0[$1.key] = AnySendable($1.value) }
        let input = TransportInput(toolName: tool, args: mappedArgs)
        return try await transport.execute(input: input)
    }

    // MARK: - Known tool inventory
    //
    // Mirrors examples/loom-mcp-manifest.json. Used by `missingTools()`
    // and by the GUI's discovery panel to list expected tools when the
    // live server hasn't been spawned yet.
    public static let knownToolNames: [String] = [
        "loom_get_topology",
        "loom_index_folder",
        "loom_list_repos",
        "loom_search_symbols",
        "loom_bm25_search",
        "loom_fuzzy_search",
        "loom_search_text",
        "loom_semantic_search",
        "loom_get_symbol",
        "loom_get_ranked_context",
        "loom_focus",
        "loom_find_importers",
        "loom_blast_radius",
        "loom_find_dead_code",
        "loom_get_class_hierarchy",
        "loom_pagerank_centrality",
        "loom_get_hotspots",
        "loom_get_changed_symbols",
        "loom_get_dependency_cycles",
        "loom_remember",
        "loom_watch_start",
        "loom_watch_stop",
        "loom_audit_agent_config",
        "loom_plan_refactoring",
        "loom_get_symbol_provenance",
        "loom_get_metrics",
        "loom_get_deps",
        "loom_workspace_stats",
    ]
}

// MARK: - Detection helper

public enum LoomDetection: Sendable {

    /// Detect whether the loom MCP server is reachable on PATH by probing
    /// for `npx`. Returns `.unknown` when PATH cannot be inspected (e.g.
    /// sandboxed environments).
    public enum Result: Sendable, Equatable {
        case present
        case missing
        case unknown
    }

    /// Best-effort probe. Looks for `npx` (the default launcher) on the
    /// user's `PATH`. Does not actually spawn the server.
    public static func probe() -> Result {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return .unknown
        }
        let dirs = pathEnv.split(separator: ":").map(String.init)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("npx")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return .present
            }
        }
        return .missing
    }
}
