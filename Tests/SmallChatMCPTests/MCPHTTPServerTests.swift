import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SmallChatMCP
import SmallChatCore
import SmallChatRuntime

// MARK: - HTTP client helpers

struct HTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    var result: [String: Any]? { json?["result"] as? [String: Any] }
    var errorCode: Int? { (json?["error"] as? [String: Any])?["code"] as? Int }
}

/// One real HTTP request over a socket.
func send(
    _ method: String,
    _ url: URL,
    headers: [String: String] = [:],
    body: String? = nil
) async throws -> HTTPReply {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let body { request.httpBody = Data(body.utf8) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    var replyHeaders: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
        if let key = key as? String, let value = value as? String { replyHeaders[key] = value }
    }
    return HTTPReply(status: http.statusCode, headers: replyHeaders, body: data)
}

/// A JSON-RPC POST to the MCP endpoint.
func rpc(
    _ url: URL,
    _ method: String,
    id: Int? = 1,
    params: String = "{}",
    session: String? = nil,
    headers: [String: String] = [:]
) async throws -> HTTPReply {
    var all = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
    if let session { all["Mcp-Session-Id"] = session }
    all.merge(headers) { _, new in new }
    let idPart = id.map { "\"id\":\($0)," } ?? ""
    return try await send("POST", url, headers: all, body: #"{"jsonrpc":"2.0",\#(idPart)"method":"\#(method)","params":\#(params)}"#)
}

/// Start a server on a free port serving the test artifact; tools echo their
/// arguments (demo/fail fails).
func startTestServer(
    authToken: String? = nil,
    enableRateLimit: Bool = false,
    rateLimitRPM: Int = 600,
    maxConnections: Int = 1000,
    recorder: CallRecorder = CallRecorder(),
    artifact: ArtifactV1? = nil
) async throws -> (server: MCPServer, endpoint: URL, base: URL) {
    let artifact: ArtifactV1 = if let artifact { artifact } else { try await makeTestArtifact() }
    let server = try MCPServer(config: MCPServerConfig(
        port: 0,
        sourcePath: "",
        dbPath: ":memory:",
        authToken: authToken,
        enableRateLimit: enableRateLimit,
        rateLimitRPM: rateLimitRPM,
        enableAudit: true,
        maxConnections: maxConnections,
        shutdownDrainSeconds: 1
    ))
    await server.setArtifact(artifact)
    await server.setToolExecutor { tool, arguments in
        recorder.record(tool.toolId)
        if tool.toolName == "fail" { return ToolResult(content: "failed on purpose", isError: true) }
        return ToolResult(codableContent: .dict(arguments))
    }
    try await server.start()
    let port = try #require(await server.boundPort)
    let base = URL(string: "http://127.0.0.1:\(port)")!
    return (server, base.appendingPathComponent("mcp"), base)
}

func initializeSession(_ endpoint: URL, version: String = "2025-06-18", headers: [String: String] = [:]) async throws -> String {
    let reply = try await rpc(endpoint, "initialize",
        params: #"{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"0"}}"#,
        headers: headers)
    #expect(reply.status == 200)
    return try #require(reply.header("Mcp-Session-Id"))
}

// MARK: - Tests

/// Real HTTP requests against the NIO server. Before 1.0 every request
/// crashed the server: request handling touched ChannelHandlerContext from a
/// Swift task, off its event loop (NIO precondition failure).
@Suite("MCP server over HTTP", .timeLimit(.minutes(1)))
struct MCPHTTPServerTests {

    @Test("initialize, notification, tools/list and tools/call over real HTTP")
    func fullExchange() async throws {
        let recorder = CallRecorder()
        let (server, endpoint, _) = try await startTestServer(recorder: recorder)

        let initialize = try await rpc(endpoint, "initialize",
            params: #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}"#)
        #expect(initialize.status == 200)
        #expect(initialize.result?["protocolVersion"] as? String == "2025-06-18")
        #expect(initialize.result?["sessionId"] == nil)
        let session = try #require(initialize.header("Mcp-Session-Id"))
        let capabilities = try #require(initialize.result?["capabilities"] as? [String: Any])
        #expect(capabilities["logging"] == nil)

        let initialized = try await rpc(endpoint, "notifications/initialized", id: nil, session: session)
        #expect(initialized.status == 202)
        #expect(initialized.body.isEmpty)

        let list = try await rpc(endpoint, "tools/list", session: session)
        let tools = try #require(list.result?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["demo__echo", "demo__fail", "other__echo"])

        let call = try await rpc(endpoint, "tools/call",
            params: #"{"name":"other__echo","arguments":{"x":1}}"#, session: session)
        #expect(call.status == 200)
        #expect(call.result?["isError"] as? Bool == false)
        #expect((call.result?["structuredContent"] as? [String: Any])?["x"] as? Int == 1)
        #expect(recorder.all == ["other/echo"])

        let failed = try await rpc(endpoint, "tools/call", params: #"{"name":"demo__fail"}"#, session: session)
        #expect(failed.result?["isError"] as? Bool == true)

        let unknown = try await rpc(endpoint, "tools/call", params: #"{"name":"echo"}"#, session: session)
        #expect(unknown.errorCode == MCPErrorCode.invalidParams.rawValue)
        #expect(recorder.all == ["other/echo", "demo/fail"])

        try await server.stop()
    }

    @Test("concurrent requests are all answered")
    func concurrentRequests() async throws {
        let (server, endpoint, _) = try await startTestServer()
        let session = try await initializeSession(endpoint)
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<32 {
                group.addTask { try await rpc(endpoint, "ping", id: i, session: session).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses.count == 32)
        #expect(statuses.allSatisfy { $0 == 200 })
        try await server.stop()
    }

    @Test("sessions: missing is 400, unknown is 404, DELETE ends one")
    func sessionValidation() async throws {
        let (server, endpoint, _) = try await startTestServer()

        #expect(try await rpc(endpoint, "tools/list").status == 400)
        #expect(try await rpc(endpoint, "tools/list", session: "made-up").status == 404)

        let session = try await initializeSession(endpoint)
        #expect(try await rpc(endpoint, "ping", session: session).status == 200)
        #expect(try await send("DELETE", endpoint, headers: ["Mcp-Session-Id": session]).status == 204)
        #expect(try await rpc(endpoint, "ping", session: session).status == 404)

        try await server.stop()
    }

    @Test("GET is 405, batches 400, non-JSON 415, unknown MCP-Protocol-Version 400, other paths 404")
    func transportRules() async throws {
        let (server, endpoint, base) = try await startTestServer()
        let session = try await initializeSession(endpoint)

        #expect(try await send("GET", endpoint).status == 405)
        let batch = try await send("POST", endpoint, headers: ["Content-Type": "application/json", "Mcp-Session-Id": session],
                                   body: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        #expect(batch.status == 400)
        let text = try await send("POST", endpoint, headers: ["Content-Type": "text/plain", "Mcp-Session-Id": session],
                                  body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(text.status == 415)
        let version = try await rpc(endpoint, "ping", session: session, headers: ["MCP-Protocol-Version": "2024-11-05"])
        #expect(version.status == 400)
        #expect(try await rpc(endpoint, "ping", session: session, headers: ["MCP-Protocol-Version": "2025-06-18"]).status == 200)
        #expect(try await send("POST", base.appendingPathComponent("rpc")).status == 404)
        #expect(try await send("GET", base.appendingPathComponent("sse")).status == 404)
        #expect(try await send("GET", base.appendingPathComponent(".well-known/mcp.json")).status == 404)

        let garbage = try await send("POST", endpoint, headers: ["Content-Type": "application/json"], body: "{not json")
        #expect(garbage.status == 400)
        #expect(garbage.errorCode == MCPErrorCode.parseError.rawValue)

        try await server.stop()
    }

    @Test("a foreign Origin is 403; loopback origins are accepted")
    func originValidation() async throws {
        let (server, endpoint, _) = try await startTestServer()
        let foreign = try await rpc(endpoint, "initialize", headers: ["Origin": "https://evil.example"])
        #expect(foreign.status == 403)
        _ = try await initializeSession(endpoint, headers: ["Origin": "http://localhost:5173"])
        try await server.stop()
    }

    @Test("a bearer token is required when configured; /health stays open")
    func bearerToken() async throws {
        let (server, endpoint, base) = try await startTestServer(authToken: "tok-123")

        #expect(try await rpc(endpoint, "initialize").status == 401)
        #expect(try await rpc(endpoint, "initialize", headers: ["Authorization": "Bearer wrong"]).status == 401)
        _ = try await initializeSession(endpoint, headers: ["Authorization": "Bearer tok-123"])
        #expect(try await send("GET", base.appendingPathComponent("health")).status == 200)
        #expect(try await send("GET", base.appendingPathComponent("metrics")).status == 401)

        try await server.stop()
    }

    @Test("rate limiting is keyed by client address, not by client-chosen session ids")
    func rateLimitKeyedByAddress() async throws {
        let (server, endpoint, _) = try await startTestServer(enableRateLimit: true, rateLimitRPM: 3)

        _ = try await initializeSession(endpoint) // 1
        #expect(try await rpc(endpoint, "ping", session: UUID().uuidString).status == 404) // 2
        #expect(try await rpc(endpoint, "ping", session: UUID().uuidString).status == 404) // 3
        let limited = try await rpc(endpoint, "ping", session: UUID().uuidString) // 4
        #expect(limited.status == 429)

        try await server.stop()
    }

    @Test("connections over maxConnections are closed")
    func connectionLimit() async throws {
        let (server, _, base) = try await startTestServer(maxConnections: 1)
        let port = try #require(base.port)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)

        let first = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
        try await Task.sleep(for: .milliseconds(200))
        let second = try await bootstrap.connect(host: "127.0.0.1", port: port).get()

        // The server closes the second connection; the first stays open.
        let secondClosed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await second.closeFuture.get(); return true }
            group.addTask { try await Task.sleep(for: .seconds(5)); return false }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(secondClosed)
        #expect(first.isActive)

        try await first.close()
        try? await second.close()
        try await group.shutdownGracefully()
        try await server.stop()
    }

    @Test("the Host header must be a loopback name on a loopback server")
    func hostValidation() async throws {
        let server = try MCPServer(config: MCPServerConfig(sourcePath: "", dbPath: ":memory:"))
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "attacker.example:3001")
        headers.add(name: "Content-Type", value: "application/json")
        let forbidden = await server.handleHTTP(MCPHTTPRequest(
            method: .POST, uri: "/mcp", headers: headers,
            body: Array(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        ))
        #expect(forbidden.status == .forbidden)

        headers.replaceOrAdd(name: "Host", value: "127.0.0.1:3001")
        let allowed = await server.handleHTTP(MCPHTTPRequest(
            method: .POST, uri: "/mcp", headers: headers,
            body: Array(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        ))
        #expect(allowed.status == .ok)
    }

    @Test("SW-REV-01: DNS names that start with 127. are not loopback, in Host or Origin")
    func rebindingNamesRefused() async throws {
        let server = try MCPServer(config: MCPServerConfig(sourcePath: "", dbPath: ":memory:"))
        func initialize(host: String, origin: String?) async -> MCPHTTPResponse {
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: host)
            headers.add(name: "Content-Type", value: "application/json")
            if let origin { headers.add(name: "Origin", value: origin) }
            return await server.handleHTTP(MCPHTTPRequest(
                method: .POST, uri: "/mcp", headers: headers,
                body: Array(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
            ))
        }
        for name in ["127.attacker.example", "127.0.0.1.nip.io", "127.0.0.1.attacker.example", "127.1", "0x7f.0.0.1"] {
            #expect(await initialize(host: "\(name):3001", origin: nil).status == .forbidden, "Host \(name)")
            #expect(await initialize(host: "127.0.0.1:3001", origin: "http://\(name):3001").status == .forbidden, "Origin \(name)")
            #expect(await initialize(host: "\(name):3001", origin: "http://\(name):3001").status == .forbidden, "Host and Origin \(name)")
        }
        for name in ["localhost", "127.0.0.1", "127.0.0.2", "127.255.255.254", "[::1]"] {
            #expect(await initialize(host: "\(name):3001", origin: "http://\(name):3001").status == .ok, "\(name)")
        }
    }

    @Test("JCS-CANONICAL-EQUIV-KEYS: a request whose member names are canonically equivalent is a parse error")
    func canonicallyEquivalentKeys() async throws {
        let server = try MCPServer(config: MCPServerConfig(sourcePath: "", dbPath: ":memory:"))
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:3001")
        headers.add(name: "Content-Type", value: "application/json")
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"arguments":{"é":1,"é":2}}}"#
        let response = await server.handleHTTP(MCPHTTPRequest(method: .POST, uri: "/mcp", headers: headers, body: Array(body.utf8)))
        #expect(response.status == .badRequest)
        guard case .dict(let reply) = try parseJSON(response.body), case .dict(let error)? = reply["error"] else {
            Issue.record("not a JSON-RPC error: \(String(decoding: response.body, as: UTF8.self))")
            return
        }
        #expect(error["code"] == .int(MCPErrorCode.parseError.rawValue))

        // Numbers read as JSON.parse reads them; an id written 1.0 is still the integer 1.
        let integral = #"{"jsonrpc":"2.0","id":1.0,"method":"initialize","params":{}}"#
        let ok = await server.handleHTTP(MCPHTTPRequest(method: .POST, uri: "/mcp", headers: headers, body: Array(integral.utf8)))
        #expect(ok.status == .ok)
        guard case .dict(let reply) = try parseJSON(ok.body) else {
            Issue.record("not JSON")
            return
        }
        #expect(reply["id"] == .int(1))
    }

    @Test("SW-REV-01: only localhost, ::1 and IPv4 literals in 127.0.0.0/8 are loopback")
    func loopbackHostNames() {
        for host in ["localhost", "LOCALHOST", "::1", "[::1]", "0:0:0:0:0:0:0:1", "127.0.0.1", "127.0.0.2", "127.255.255.255"] {
            #expect(MCPServer.isLoopbackHost(host), "\(host)")
        }
        for host in ["127.attacker.example", "127.0.0.1.nip.io", "127.", "127", "127.1", "127.0.0.256", "0127.0.0.1",
                     "0x7f.0.0.1", "128.0.0.1", "10.0.0.1", "0.0.0.0", "::", "::ffff:8.8.8.8", "localhost.attacker.example",
                     "attacker-localhost", "", " 127.0.0.1"] {
            #expect(!MCPServer.isLoopbackHost(host), "\(host)")
        }
    }

    @Test("the audit log records each request and verifies")
    func auditLog() async throws {
        let (server, endpoint, _) = try await startTestServer()
        let session = try await initializeSession(endpoint)
        _ = try await rpc(endpoint, "tools/call", params: #"{"name":"demo__fail"}"#, session: session)
        let entries = await server.audit.all()
        #expect(entries.map(\.method) == ["initialize", "tools/call"])
        #expect(entries.last?.success == false)
        #expect(entries.last?.clientId == "127.0.0.1")
        #expect(await server.audit.verifyChain())
        try await server.stop()
    }
}

// MARK: - serve's runtime: tools run through their provider's endpoint

@Suite("MCP toolkit runtime", .timeLimit(.minutes(1)))
struct MCPToolkitRuntimeTests {

    @Test("a tool runs at its provider's MCP endpoint, and the upstream result passes through")
    func upstreamMCPCall() async throws {
        // Upstream: a smallchat MCP server whose tools echo their arguments.
        let upstreamCalls = CallRecorder()
        let (upstream, upstreamEndpoint, _) = try await startTestServer(recorder: upstreamCalls)

        // The served toolkit: provider "up" whose endpoint is the upstream server.
        let artifact = try await makeTestArtifact(
            endpoints: ["up": upstreamEndpoint.absoluteString],
            tools: [("up", "demo__echo"), ("nowhere", "echo")]
        )
        let toolkit = try await MCPToolkit.make(artifact: artifact)
        #expect(toolkit.unavailable.map(\.toolId) == ["nowhere/echo"])

        let server = try MCPServer(config: MCPServerConfig(port: 0, sourcePath: "", dbPath: ":memory:", shutdownDrainSeconds: 1))
        await server.setArtifact(artifact)
        await server.setRuntime(toolkit.runtime)
        try await server.start()
        let endpoint = URL(string: "http://127.0.0.1:\(try #require(await server.boundPort))/mcp")!
        let session = try await initializeSession(endpoint)

        let call = try await rpc(endpoint, "tools/call",
            params: #"{"name":"up__demo__echo","arguments":{"msg":"hé"}}"#, session: session)
        #expect(call.result?["isError"] as? Bool == false)
        #expect((call.result?["structuredContent"] as? [String: Any])?["msg"] as? String == "hé")
        #expect(upstreamCalls.all == ["demo/echo"])

        let nowhere = try await rpc(endpoint, "tools/call", params: #"{"name":"nowhere__echo"}"#, session: session)
        #expect(nowhere.result?["isError"] as? Bool == true)
        let text = ((nowhere.result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("records no launch spec or endpoint"))

        try await server.stop()
        try await upstream.stop()
    }

    @Test("a manifest directory loads with endpoints, and serve's start() wires it")
    func loadFromManifests() async throws {
        let upstreamCalls = CallRecorder()
        let (upstream, upstreamEndpoint, _) = try await startTestServer(recorder: upstreamCalls)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smallchat-manifests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"id":"up","name":"Upstream","transportType":"mcp","endpoint":"\(upstreamEndpoint.absoluteString)",
         "tools":[{"name":"demo__echo","description":"Echo the arguments back","providerId":"up","transportType":"mcp",
                   "inputSchema":{"type":"object","properties":{"msg":{"type":"string"}}}}]}
        """
        try manifest.write(to: dir.appendingPathComponent("up.json"), atomically: true, encoding: .utf8)

        let server = try MCPServer(config: MCPServerConfig(port: 0, sourcePath: dir.path, dbPath: ":memory:", shutdownDrainSeconds: 1))
        try await server.start()
        let catalog = try #require(await server.toolCatalog)
        #expect(catalog.tools.map(\.name) == ["up__demo__echo"])
        #expect(catalog.tools.first?.description == "Echo the arguments back")

        let endpoint = URL(string: "http://127.0.0.1:\(try #require(await server.boundPort))/mcp")!
        let session = try await initializeSession(endpoint)
        let call = try await rpc(endpoint, "tools/call",
            params: #"{"name":"up__demo__echo","arguments":{"msg":"hi"}}"#, session: session)
        #expect(call.result?["isError"] as? Bool == false)
        #expect(upstreamCalls.all == ["demo/echo"])

        try await server.stop()
        try await upstream.stop()
    }
}
