import ArgumentParser
import Foundation
import SmallChat

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve a toolkit as an MCP server over Streamable HTTP",
        discussion: """
        Tools are listed as <provider>__<tool> (or, with --provider, one provider's \
        tools under their upstream names), and tools/call runs exactly the named tool \
        through its provider's manifest endpoint: MCP servers over Streamable HTTP, \
        REST APIs as POST <endpoint>/<tool>. Tools whose provider declares no such \
        endpoint are listed but fail when called.
        """
    )

    @Option(name: .shortAndLong, help: "Manifest directory, manifest file, or compiled artifact (.json)")
    var source: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 3001

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Option(help: "SQLite database path for sessions")
    var dbPath: String = "smallchat.db"

    @Option(help: "Serve only this provider's tools, under their upstream names")
    var provider: String?

    @Flag(help: "Also list the smallchat_dispatch meta-tool (semantic intent dispatch)")
    var semanticDispatch: Bool = false

    @Flag(help: "Require a bearer token (from SMALLCHAT_MCP_TOKEN, or --auth-token-file)")
    var auth: Bool = false

    @Option(help: "File holding the bearer token; created with a random token (mode 0600) if missing")
    var authTokenFile: String = "~/.smallchat/serve-token"

    @Flag(help: "Enable rate limiting (per client address)")
    var rateLimit: Bool = false

    @Option(help: "Max requests per minute")
    var rateLimitRpm: Int = 600

    @Flag(help: "Enable audit logging (in memory, HMAC-chained)")
    var audit: Bool = false

    @Option(help: "Maximum concurrent connections (0 = unlimited)")
    var maxConnections: Int = 1000

    @Option(help: "Session TTL in hours")
    var sessionTtl: Double = 24

    func run() async throws {
        print("Loading toolkit from \(source)...")
        let toolkit = try await MCPToolkit.load(source: source)
        let naming: MCPToolNaming = provider.map { .provider($0) } ?? .aggregate
        let catalog = MCPToolCatalog(artifact: toolkit.artifact, naming: naming)
        if case .provider(let id) = naming, catalog.tools.isEmpty {
            print("No tools for provider \(id).")
            throw ExitCode.failure
        }

        let token = try auth ? resolveAuthToken() : nil
        if !auth && !MCPServer.isLoopbackHost(host) {
            FileHandle.standardError.write(Data(
                "Warning: serving on \(host) without --auth; anyone who can reach it can call every tool.\n".utf8
            ))
        }

        let config = MCPServerConfig(
            port: port,
            host: host,
            sourcePath: "",
            dbPath: dbPath,
            authToken: token?.value,
            enableRateLimit: rateLimit,
            rateLimitRPM: rateLimitRpm,
            enableAudit: audit,
            sessionTTLMs: Int(sessionTtl * 3_600_000),
            maxConnections: maxConnections,
            toolNaming: naming,
            semanticDispatch: semanticDispatch
        )

        let server = try MCPServer(config: config)
        await server.setArtifact(toolkit.artifact)
        await server.setRuntime(toolkit.runtime, semanticDispatch: semanticDispatch)

        print("  \(catalog.tools.count) tools listed (\(naming == .aggregate ? "<provider>__<tool>" : "upstream names"))")
        for skipped in catalog.skipped {
            print("  not listed: \(skipped.toolId): \(skipped.reason)")
        }
        let listed = Set(catalog.tools.map(\.toolId))
        for unavailable in toolkit.unavailable where listed.contains(unavailable.toolId) {
            print("  cannot run: \(unavailable.toolId): \(unavailable.reason)")
        }
        if semanticDispatch {
            print("  Semantic dispatch: smallchat_dispatch")
        }
        print("  Auth: \(token.map { "bearer token (\($0.origin))" } ?? "none")")
        print("  Rate limiting: \(rateLimit ? "enabled (\(rateLimitRpm) rpm)" : "disabled")")
        print("  Audit: \(audit ? "enabled" : "disabled")")
        print("  Session TTL: \(sessionTtl)h")
        print("  Database: \(dbPath)")

        try await server.start()

        print("\nServer running (MCP \(mcpSupportedProtocolVersions.joined(separator: ", "))). Press Ctrl+C to stop.")
        print("  MCP:     http://\(host):\(port)\(MCPServer.endpointPath)")
        print("  Health:  http://\(host):\(port)/health")
        print("  Metrics: http://\(host):\(port)/metrics")

        // Keep running until signal, then shut down gracefully
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGINT, SIG_IGN)
            let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigSource.setEventHandler {
                sigSource.cancel()
                print("\nShutting down...")
                continuation.resume()
            }
            sigSource.resume()
        }

        try await server.stop()
    }

    /// The bearer token: `SMALLCHAT_MCP_TOKEN`, else the token file (created
    /// with a random token and mode 0600 when missing).
    private func resolveAuthToken() throws -> (value: String, origin: String) {
        if let env = ProcessInfo.processInfo.environment["SMALLCHAT_MCP_TOKEN"], !env.isEmpty {
            return (env, "SMALLCHAT_MCP_TOKEN")
        }
        let path = (authTokenFile as NSString).expandingTildeInPath
        if let existing = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return (existing, path)
        }
        let token = MCPServerConfig.generateAuthToken()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ValidationError("Could not write the token file \(path)")
        }
        return (token, "new token in \(path)")
    }
}
