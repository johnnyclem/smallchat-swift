// MARK: - MCPServer — NIO-based Streamable HTTP server for the MCP protocol

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SmallChatCore
import SmallChatRuntime

// MARK: - Server Configuration

/// Configuration for the MCP HTTP server.
public struct MCPServerConfig: Sendable {
    /// Port to listen on (0 picks a free port; see `MCPServer.boundPort`).
    public let port: Int
    /// Host to bind to.
    public let host: String
    /// Toolkit to serve when `start()` is called and no artifact was set:
    /// a directory of provider manifests, one manifest, or a compiled
    /// artifact (see `MCPToolkit.load`). Empty: serve only what is set
    /// programmatically.
    public let sourcePath: String
    /// SQLite database path for sessions.
    public let dbPath: String
    /// Bearer token every request except `GET /health` must carry
    /// (`Authorization: Bearer <token>`). nil: no authentication.
    public let authToken: String?
    /// Enable rate limiting (per client address).
    public let enableRateLimit: Bool
    /// Max requests per minute per client address.
    public let rateLimitRPM: Int
    /// Enable audit logging.
    public let enableAudit: Bool
    /// Key for the audit log's HMAC chain. nil: a random key per server.
    public let auditKey: Data?
    /// Session TTL in milliseconds.
    public let sessionTTLMs: Int
    /// Origin sent in `Access-Control-Allow-Origin`, and accepted as `Origin`.
    public let corsOrigin: String
    /// Further `Origin` values accepted. Requests without an `Origin` header
    /// (non-browser clients) are always accepted; loopback origins are
    /// accepted while the server is bound to a loopback address.
    public let allowedOrigins: [String]
    /// Maximum concurrent client connections; connections over the limit are
    /// closed at once. 0 = unlimited.
    public let maxConnections: Int
    /// Maximum request body size in bytes. Prevents memory exhaustion.
    public let maxRequestBodyBytes: Int
    /// Graceful shutdown drain timeout in seconds.
    public let shutdownDrainSeconds: Int
    /// How tools are named in `tools/list` and `tools/call`.
    public let toolNaming: MCPToolNaming
    /// List the `smallchat_dispatch` meta-tool (semantic dispatch through the
    /// runtime) when a runtime is wired. Off by default: every other call
    /// runs exactly the named tool.
    public let semanticDispatch: Bool

    public init(
        port: Int = 3000,
        host: String = "127.0.0.1",
        sourcePath: String,
        dbPath: String = "smallchat.db",
        authToken: String? = nil,
        enableRateLimit: Bool = false,
        rateLimitRPM: Int = 600,
        enableAudit: Bool = false,
        auditKey: Data? = nil,
        sessionTTLMs: Int = 86_400_000,
        corsOrigin: String = "http://127.0.0.1",
        allowedOrigins: [String] = [],
        maxConnections: Int = 1000,
        maxRequestBodyBytes: Int = 1_048_576,
        shutdownDrainSeconds: Int = 30,
        toolNaming: MCPToolNaming = .aggregate,
        semanticDispatch: Bool = false
    ) {
        self.port = port
        self.host = host
        self.sourcePath = sourcePath
        self.dbPath = dbPath
        self.authToken = authToken
        self.enableRateLimit = enableRateLimit
        self.rateLimitRPM = rateLimitRPM
        self.enableAudit = enableAudit
        self.auditKey = auditKey
        self.sessionTTLMs = sessionTTLMs
        self.corsOrigin = corsOrigin
        self.allowedOrigins = allowedOrigins
        self.maxConnections = maxConnections
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.shutdownDrainSeconds = shutdownDrainSeconds
        self.toolNaming = toolNaming
        self.semanticDispatch = semanticDispatch
    }

    /// A fresh random bearer token (64 hex characters).
    public static func generateAuthToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
}

// MARK: - Server Metrics

/// Lightweight request metrics for observability.
public actor ServerMetrics {
    private(set) var totalRequests: Int = 0
    private(set) var totalErrors: Int = 0
    private(set) var activeConnections: Int = 0
    private(set) var peakConnections: Int = 0
    private(set) var rejectedConnections: Int = 0
    private let startTime: ContinuousClock.Instant

    public init() {
        self.startTime = ContinuousClock.now
    }

    /// Record a completed request.
    public func recordRequest(success: Bool) {
        totalRequests += 1
        if !success { totalErrors += 1 }
    }

    /// Track connection open/close.
    public func connectionOpened() {
        activeConnections += 1
        if activeConnections > peakConnections {
            peakConnections = activeConnections
        }
    }

    public func connectionClosed() {
        activeConnections = max(0, activeConnections - 1)
    }

    /// Count a connection closed because the server was at `maxConnections`.
    public func connectionRejected() {
        rejectedConnections += 1
    }

    /// Get a snapshot of current metrics.
    public func snapshot() -> [String: AnyCodableValue] {
        let uptime = ContinuousClock.now - startTime
        let uptimeSeconds = Int(uptime.components.seconds)
        return [
            "uptime_seconds": .int(uptimeSeconds),
            "total_requests": .int(totalRequests),
            "total_errors": .int(totalErrors),
            "active_connections": .int(activeConnections),
            "peak_connections": .int(peakConnections),
            "rejected_connections": .int(rejectedConnections),
            "error_rate": .double(totalRequests > 0 ? Double(totalErrors) / Double(totalRequests) : 0),
        ]
    }
}

// MARK: - HTTP request/response values

/// One HTTP request, as the server's request logic sees it.
struct MCPHTTPRequest: Sendable {
    var method: HTTPMethod
    var uri: String
    var headers: HTTPHeaders
    var body: [UInt8]
    /// Client IP address (no port).
    var remoteAddress: String?

    var path: String {
        String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// One HTTP response.
struct MCPHTTPResponse: Sendable {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders = HTTPHeaders()
    var body: [UInt8] = []

    static func json<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) -> MCPHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var response = MCPHTTPResponse(status: status)
        response.headers.add(name: "Content-Type", value: "application/json")
        response.body = Array((try? encoder.encode(value)) ?? Data("{}".utf8))
        return response
    }

    /// A JSON-RPC error carried by an HTTP error status.
    static func rpcError(_ status: HTTPResponseStatus, id: JSONRPCId = .null, code: MCPErrorCode, _ message: String) -> MCPHTTPResponse {
        json(status, JSONRPCResponse.error(id, code: code.rawValue, message: message))
    }
}

// MARK: - MCPServer Actor

/// MCP server over Streamable HTTP (protocol versions in
/// `mcpSupportedProtocolVersions`).
///
/// One MCP endpoint, `/mcp`: `POST` carries one JSON-RPC message and is
/// answered with `application/json` (`202 Accepted` for a notification);
/// `DELETE` ends a session; `GET` is `405` (the server does not open
/// server-to-client streams). `initialize` opens a session whose id comes
/// back in `Mcp-Session-Id`; every other request must carry it (`400` when
/// missing, `404` when unknown or expired). `GET /health` and `GET /metrics`
/// report status.
///
/// In front of MCP: Host and Origin checks (`403`), an optional bearer token
/// (`401`), a body size cap (`413`), JSON-only bodies (`415`), per-address
/// rate limiting (`429`), and a connection cap.
///
/// `tools/call` runs exactly the named tool through the wired runtime (see
/// `setRuntime(_:semanticDispatch:)`). Built on SwiftNIO; request work runs
/// in Swift tasks and every write hops back to the connection's event loop.
public actor MCPServer {

    private let config: MCPServerConfig
    private let sessionStore: SessionStore
    private let resourceRegistry: ResourceRegistry
    private let promptRegistry: PromptRegistry
    private let rateLimiter: RateLimiter
    private let auditLog: AuditLog
    private let router: MCPRouter
    private let metrics: ServerMetrics
    private let connections: ConnectionGate
    private var artifact: SerializedArtifact?
    private var eventLoopGroup: (any EventLoopGroup)?
    private var serverChannel: Channel?
    /// Requests being answered right now (what `stop()` drains).
    private var inFlightRequests = 0

    public init(config: MCPServerConfig) throws {
        self.config = config
        self.sessionStore = try SessionStore(dbPath: config.dbPath)
        self.resourceRegistry = ResourceRegistry()
        self.promptRegistry = PromptRegistry()
        self.rateLimiter = RateLimiter(maxRPM: config.rateLimitRPM)
        self.auditLog = AuditLog(hmacKey: config.auditKey ?? AuditLog.generateKey())
        self.metrics = ServerMetrics()
        self.connections = ConnectionGate(limit: config.maxConnections)
        self.router = MCPRouter(
            sessionStore: sessionStore,
            resourceRegistry: resourceRegistry,
            promptRegistry: promptRegistry,
            options: RouterOptions(
                serverName: mcpServerName,
                serverVersion: mcpServerVersion,
                sessionTTLMs: config.sessionTTLMs,
                toolNaming: config.toolNaming
            )
        )
    }

    // MARK: - Public Accessors

    /// Access the resource registry for registering handlers.
    public var resources: ResourceRegistry { resourceRegistry }

    /// Access the prompt registry for registering handlers.
    public var prompts: PromptRegistry { promptRegistry }

    /// Access the audit log.
    public var audit: AuditLog { auditLog }

    /// Access server metrics.
    public var serverMetrics: ServerMetrics { metrics }

    /// The port the server listens on, once started.
    public var boundPort: Int? { serverChannel?.localAddress?.port }

    /// The tools `tools/list` serves (nil until an artifact is set or loaded).
    public var toolCatalog: MCPToolCatalog? {
        get async { await router.toolCatalog }
    }

    /// Serve the tools of `artifact`.
    public func setArtifact(_ artifact: SerializedArtifact) async {
        self.artifact = artifact
        await router.setArtifact(artifact)
    }

    /// Run `tools/call` through `executor`.
    public func setToolExecutor(_ executor: @escaping MCPToolExecutor) async {
        await router.setToolExecutor(executor)
    }

    /// Wire a `ToolRuntime` so `tools/call` runs tools.
    ///
    /// A call runs exactly the listed tool: the runtime's class named after the
    /// tool's provider, and that class's implementation with the tool's
    /// upstream name. There is no semantic fallback on `tools/call`. With
    /// `semanticDispatch`, the `smallchat_dispatch` meta-tool is listed and
    /// resolves intents through `tieredDispatch`.
    public func setRuntime(_ runtime: ToolRuntime, semanticDispatch: Bool = false) async {
        await router.setToolExecutor { [runtime] tool, arguments in
            let classes = await runtime.context.getClasses()
            guard let toolClass = classes.first(where: { $0.name == tool.providerId }),
                  let imp = toolClass.dispatchTable.values.first(where: { $0.toolName == tool.toolName }) else {
                throw MCPToolUnavailableError(toolId: tool.toolId, reason: "the runtime has no implementation for it")
            }
            return try await imp.execute(args: arguments.mapValues { $0 as any Sendable })
        }
        if semanticDispatch {
            await router.setSemanticDispatchHandler { [runtime] intent, arguments in
                try await tieredDispatch(
                    context: runtime.context,
                    intent: intent,
                    args: arguments.mapValues { $0 as any Sendable }
                )
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the MCP server.
    ///
    /// When no artifact was set and `sourcePath` is not empty, the toolkit is
    /// loaded from it (`MCPToolkit.load`) and its runtime wired.
    public func start() async throws {
        if artifact == nil, !config.sourcePath.isEmpty {
            let toolkit = try await MCPToolkit.load(source: config.sourcePath)
            await setArtifact(toolkit.artifact)
            await setRuntime(toolkit.runtime, semanticDispatch: config.semanticDispatch)
        }

        // Prune expired sessions
        try await sessionStore.prune(maxAgeMs: config.sessionTTLMs)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let maxBodyBytes = config.maxRequestBodyBytes
        let connections = self.connections
        let metrics = self.metrics
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                // Over the connection limit: close at once.
                guard connections.acquire() else {
                    Task { await metrics.connectionRejected() }
                    return channel.close()
                }
                Task { await metrics.connectionOpened() }
                channel.closeFuture.whenComplete { _ in
                    connections.release()
                    Task { await metrics.connectionClosed() }
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        MCPHTTPHandler(server: self, maxBodyBytes: maxBodyBytes)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        do {
            self.serverChannel = try await bootstrap.bind(host: config.host, port: config.port).get()
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Stop the MCP server with graceful drain.
    ///
    /// Stops accepting connections, waits up to `shutdownDrainSeconds` for
    /// in-flight requests to be answered, then closes every connection.
    public func stop() async throws {
        try? await serverChannel?.close()
        serverChannel = nil

        let drainDeadline = ContinuousClock.now + .seconds(config.shutdownDrainSeconds)
        while inFlightRequests > 0, ContinuousClock.now < drainDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        try await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil
    }

    // MARK: - HTTP

    /// The MCP endpoint path.
    public static let endpointPath = "/mcp"

    /// Answer one HTTP request.
    func handleHTTP(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        inFlightRequests += 1
        defer { inFlightRequests -= 1 }
        var response = await route(request)
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: config.corsOrigin)
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Methods", value: "POST, GET, DELETE, OPTIONS")
        response.headers.replaceOrAdd(
            name: "Access-Control-Allow-Headers",
            value: "Content-Type, Accept, Authorization, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID"
        )
        response.headers.replaceOrAdd(name: "Access-Control-Expose-Headers", value: "Mcp-Session-Id")
        response.headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        return response
    }

    private func route(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        // DNS rebinding: a loopback server only answers loopback Host names,
        // and browsers' requests only from accepted origins.
        if let host = request.headers.first(name: "Host"), !hostAllowed(host) {
            return .json(.forbidden, ["error": "Forbidden host"])
        }
        if let origin = request.headers.first(name: "Origin"), !originAllowed(origin) {
            return .json(.forbidden, ["error": "Forbidden origin"])
        }

        if request.method == .OPTIONS {
            return MCPHTTPResponse(status: .noContent)
        }

        if request.method == .GET && request.path == "/health" {
            return .json(.ok, await healthResponse())
        }

        if let token = config.authToken {
            let header = request.headers.first(name: "Authorization") ?? ""
            let provided = header.range(of: "Bearer ", options: [.caseInsensitive, .anchored])
                .map { String(header[$0.upperBound...]) }
            guard let provided, constantTimeEquals(provided, token) else {
                var unauthorized = MCPHTTPResponse.json(.unauthorized, ["error": "Unauthorized"])
                unauthorized.headers.add(name: "WWW-Authenticate", value: "Bearer")
                return unauthorized
            }
        }

        if request.method == .GET && request.path == "/metrics" {
            return .json(.ok, await metrics.snapshot())
        }

        guard request.path == Self.endpointPath else {
            return .json(.notFound, ["error": "Not found"])
        }

        switch request.method {
        case .POST:
            return await handlePost(request)
        case .DELETE:
            return await handleDelete(request)
        default:
            var notAllowed = MCPHTTPResponse.json(.methodNotAllowed, ["error": "Method not allowed"])
            notAllowed.headers.add(name: "Allow", value: "POST, DELETE")
            return notAllowed
        }
    }

    private func handleDelete(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard let sessionId = request.headers.first(name: "Mcp-Session-Id"), !sessionId.isEmpty else {
            return .rpcError(.badRequest, code: .invalidRequest, "Missing Mcp-Session-Id header")
        }
        let deleted = (try? await sessionStore.delete(sessionId)) ?? false
        return deleted
            ? MCPHTTPResponse(status: .noContent)
            : .rpcError(.notFound, code: .sessionExpired, "Session not found")
    }

    private func handlePost(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        let startTime = ContinuousClock.now

        let contentType = request.headers.first(name: "Content-Type") ?? ""
        guard contentType.lowercased().contains("application/json") else {
            return .rpcError(.unsupportedMediaType, code: .invalidRequest, "Content-Type must be application/json")
        }
        if let version = request.headers.first(name: "MCP-Protocol-Version"),
           !mcpSupportedProtocolVersions.contains(version) {
            return .rpcError(.badRequest, code: .invalidRequest, "Unsupported MCP-Protocol-Version: \(version)")
        }

        // Rate limit by client address: session ids are chosen by clients.
        if config.enableRateLimit {
            let allowed = await rateLimiter.check(clientId: request.remoteAddress ?? "unknown")
            if !allowed {
                await metrics.recordRequest(success: false)
                return .rpcError(.tooManyRequests, code: .unsupportedVersion, "Rate limit exceeded")
            }
        }

        // Parse one JSON-RPC message.
        let json = try? JSONSerialization.jsonObject(with: Data(request.body), options: [.fragmentsAllowed])
        if json is [Any] {
            return .rpcError(.badRequest, code: .invalidRequest, "JSON-RPC batches are not supported")
        }
        guard json is [String: Any],
              let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: Data(request.body)) else {
            return .rpcError(.badRequest, code: .parseError, "Parse error")
        }
        // A client's response to a server request (the server sends none).
        if dict["method"] == nil, dict["result"] != nil || dict["error"] != nil {
            return MCPHTTPResponse(status: .accepted)
        }
        let rpc: JSONRPCRequest
        switch validateRPCEnvelope(dict) {
        case .success(let valid):
            rpc = valid
        case .failure(let error):
            return .json(.badRequest, JSONRPCResponse(id: .null, error: error))
        }

        // initialize opens a session; everything else needs a live one.
        let rpcResponse: JSONRPCResponse?
        let sessionId: String?
        var extraHeaders = HTTPHeaders()
        if rpc.method == MCPMethod.initialize.rawValue {
            let (response, session) = await router.initialize(request: rpc)
            if let session { extraHeaders.add(name: "Mcp-Session-Id", value: session.id) }
            sessionId = session?.id
            rpcResponse = rpc.isNotification ? nil : response
        } else {
            guard let provided = request.headers.first(name: "Mcp-Session-Id"), !provided.isEmpty else {
                return .rpcError(.badRequest, id: rpc.id ?? .null, code: .invalidRequest, "Missing Mcp-Session-Id header")
            }
            guard (try? await sessionStore.activeSession(provided, ttlMs: config.sessionTTLMs)) != nil else {
                return .rpcError(.notFound, id: rpc.id ?? .null, code: .sessionExpired, "Session not found or expired")
            }
            sessionId = provided
            rpcResponse = await router.handle(request: rpc, sessionId: provided)
        }

        let isToolError: Bool = {
            if case .dict(let result)? = rpcResponse?.result, case .bool(true)? = result["isError"] { return true }
            return false
        }()
        let success = rpcResponse?.error == nil && !isToolError
        await metrics.recordRequest(success: success)

        if config.enableAudit {
            let elapsed = ContinuousClock.now - startTime
            let durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            await auditLog.log(AuditEntry(
                method: rpc.method,
                sessionId: sessionId,
                clientId: request.remoteAddress,
                success: success,
                durationMs: durationMs,
                error: rpcResponse?.error?.message ?? (isToolError ? "tool returned isError" : nil)
            ))
        }

        guard let rpcResponse else {
            // A notification: accepted, no body.
            var accepted = MCPHTTPResponse(status: .accepted)
            accepted.headers.add(contentsOf: extraHeaders)
            return accepted
        }
        var response = MCPHTTPResponse.json(.ok, rpcResponse)
        response.headers.add(contentsOf: extraHeaders)
        return response
    }

    /// Build the health check response.
    func healthResponse() async -> [String: AnyCodableValue] {
        let sessionCount = (try? await sessionStore.count()) ?? 0
        return [
            "status": .string("ok"),
            "version": .string(mcpServerVersion),
            "protocolVersions": .array(mcpSupportedProtocolVersions.map { .string($0) }),
            "tools": .int(artifact?.stats.toolCount ?? 0),
            "providers": .int(artifact?.stats.providerCount ?? 0),
            "sessions": .int(sessionCount),
        ]
    }

    // MARK: - Perimeter checks

    private var boundToLoopback: Bool { Self.isLoopbackHost(config.host) }

    private func hostAllowed(_ hostHeader: String) -> Bool {
        guard boundToLoopback else { return true }
        return Self.isLoopbackHost(Self.hostName(fromAuthority: hostHeader))
    }

    private func originAllowed(_ origin: String) -> Bool {
        if origin == config.corsOrigin || config.allowedOrigins.contains(origin) { return true }
        guard boundToLoopback, let url = URL(string: origin), let host = url.host else { return false }
        return Self.isLoopbackHost(host)
    }

    /// Whether `host` names the loopback interface.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.")
    }

    /// `example.com:3001` → `example.com`; `[::1]:3001` → `::1`.
    static func hostName(fromAuthority authority: String) -> String {
        if authority.hasPrefix("[") {
            return String(authority.dropFirst().prefix { $0 != "]" })
        }
        return String(authority.prefix { $0 != ":" })
    }
}

// MARK: - Helpers

/// Constant-time comparison: the time taken does not depend on where the
/// strings differ (only on whether their lengths do).
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count {
        diff |= x[i] ^ y[i]
    }
    return diff == 0
}

/// Counts open connections against a limit (0 = unlimited).
final class ConnectionGate: Sendable {
    private let limit: Int
    private let count = PlatformLock(initialState: 0)

    init(limit: Int) {
        self.limit = limit
    }

    /// Take a slot; false when the limit is reached.
    func acquire() -> Bool {
        count.withLock { open in
            if limit > 0 && open >= limit { return false }
            open += 1
            return true
        }
    }

    func release() {
        count.withLock { $0 = max(0, $0 - 1) }
    }

    var active: Int { count.withLock { $0 } }
}

// MARK: - NIO HTTP Handler

/// SwiftNIO channel handler for MCP HTTP requests.
///
/// Collects a request on the event loop, answers it in a Swift task, and
/// hops back to the event loop to write: `ChannelHandlerContext` is only
/// ever touched on its event loop.
private final class MCPHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MCPServer
    private let maxBodyBytes: Int
    private var head: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    private var bodyTooLarge: Bool = false

    init(server: MCPServer, maxBodyBytes: Int) {
        self.server = server
        self.maxBodyBytes = maxBodyBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            bodyBuffer.clear()
            bodyTooLarge = false
        case .body(var body):
            if bodyBuffer.readableBytes + body.readableBytes > maxBodyBytes {
                bodyTooLarge = true
            } else {
                bodyBuffer.writeBuffer(&body)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let keepAlive = head.isKeepAlive

            if bodyTooLarge {
                write(.json(.payloadTooLarge, ["error": "Request body too large", "limit": String(maxBodyBytes)]),
                      keepAlive: false, context: context)
                return
            }

            let request = MCPHTTPRequest(
                method: head.method,
                uri: head.uri,
                headers: head.headers,
                body: bodyBuffer.readBytes(length: bodyBuffer.readableBytes) ?? [],
                remoteAddress: context.channel.remoteAddress?.ipAddress
            )
            let loop = context.eventLoop
            let bound = NIOLoopBound((handler: self, context: context), eventLoop: loop)
            let server = self.server
            Task {
                let response = await server.handleHTTP(request)
                loop.execute {
                    let (handler, context) = bound.value
                    handler.write(response, keepAlive: keepAlive, context: context)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func write(_ response: MCPHTTPResponse, keepAlive: Bool, context: ChannelHandlerContext) {
        var headers = response.headers
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive {
            let channel = context.channel
            done.whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
