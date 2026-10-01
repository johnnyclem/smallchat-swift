import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import SmallChatCore
@testable import SmallChatTransport

// MARK: - Recording server

/// Loopback HTTP server that answers every request with `200 {}` and records
/// the request line and body it received.
final class RecordingHTTPServer: Sendable {
    struct Request: Sendable {
        let method: String
        let uri: String
        let body: String
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let recorded: PlatformLock<[Request]>

    var baseURL: URL { URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)")! }
    var requests: [Request] { recorded.withLock { $0 } }

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, recorded: PlatformLock<[Request]>) {
        self.group = group
        self.channel = channel
        self.recorded = recorded
    }

    static func start() async throws -> RecordingHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorded = PlatformLock<[Request]>(initialState: [])
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(RecordingHandler(recorded: recorded))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return RecordingHTTPServer(group: group, channel: channel, recorded: recorded)
    }

    func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

private final class RecordingHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorded: PlatformLock<[RecordingHTTPServer.Request]>
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(recorded: PlatformLock<[RecordingHTTPServer.Request]>) {
        self.recorded = recorded
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let request = RecordingHTTPServer.Request(
                method: head.method.rawValue,
                uri: head.uri,
                body: body.readString(length: body.readableBytes) ?? ""
            )
            recorded.withLock { $0.append(request) }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "2")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "{}")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

// MARK: - Tests

/// HTTPTransport must build requests from the route: `{param}` placeholders
/// filled in (percent-encoded), declared query params in the query string, and
/// GET arguments never silently dropped.
@Suite("HTTPTransport request building")
struct HTTPRequestBuildingTests {

    private func transport(_ server: RecordingHTTPServer, routes: [HTTPTransportRoute] = []) async -> HTTPTransport {
        let transport = HTTPTransport(config: TransportConfig(baseURL: server.baseURL, timeout: 10))
        await transport.addRoutes(routes)
        return transport
    }

    @Test("path placeholders are filled and declared query params are sent")
    func pathAndQueryParams() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "getPet", method: .GET, path: "/pets/{petId}",
            queryParams: ["verbose"], pathParams: ["petId"]
        )])

        let output = try await transport.execute(input: TransportInput(
            toolName: "getPet",
            args: ["petId": AnySendable(42), "verbose": AnySendable(true)]
        ))
        try await server.shutdown()

        #expect(output.statusCode == 200)
        #expect(server.requests.map(\.method) == ["GET"])
        #expect(server.requests.map(\.uri) == ["/pets/42?verbose=true"])
    }

    @Test("path values are percent-encoded as one segment")
    func pathValuesEncoded() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "getFile", method: .GET, path: "/files/{name}", pathParams: ["name"]
        )])

        _ = try await transport.execute(input: TransportInput(
            toolName: "getFile",
            args: ["name": AnySendable("a/b c?d#e")]
        ))
        try await server.shutdown()

        #expect(server.requests.map(\.uri) == ["/files/a%2Fb%20c%3Fd%23e"])
    }

    @Test("query values are percent-encoded, including & = + and spaces")
    func queryValuesEncoded() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "search", method: .GET, path: "/search", queryParams: ["q"]
        )])

        _ = try await transport.execute(input: TransportInput(
            toolName: "search",
            args: ["q": AnySendable("a&b=c+d e")]
        ))
        try await server.shutdown()

        #expect(server.requests.map(\.uri) == ["/search?q=a%26b%3Dc%2Bd%20e"])
    }

    @Test("a placeholder without a value fails the call without sending a request")
    func missingPathParam() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "getPet", method: .GET, path: "/pets/{petId}", pathParams: ["petId"]
        )])

        let output = try await transport.execute(input: TransportInput(toolName: "getPet"))
        try await server.shutdown()

        #expect(output.isError)
        #expect(server.requests.isEmpty)
    }

    @Test("GET arguments without declared query params go in the query string")
    func undeclaredGetArgs() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server)

        _ = try await transport.execute(input: TransportInput(
            toolName: "list",
            args: ["limit": AnySendable(5), "tag": AnySendable("x y")],
            method: .GET
        ))
        try await server.shutdown()

        #expect(server.requests.map(\.uri) == ["/list?limit=5&tag=x%20y"])
    }

    @Test("DELETE without a route sends its arguments in the query; with a route, in the body")
    func deleteArgs() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "deletePet", method: .DELETE, path: "/pets/{petId}", pathParams: ["petId"]
        )])

        _ = try await transport.execute(input: TransportInput(
            toolName: "purge", args: ["older_than": AnySendable("7d")], method: .DELETE
        ))
        _ = try await transport.execute(input: TransportInput(
            toolName: "deletePet", args: ["petId": AnySendable(3), "reason": AnySendable("sold")]
        ))
        try await server.shutdown()

        #expect(server.requests.map(\.uri) == ["/purge?older_than=7d", "/pets/3"])
        #expect(server.requests.first?.body == "")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(server.requests[1].body.utf8)) as? [String: Any])
        #expect(body["reason"] as? String == "sold")
    }

    @Test("POST sends path params in the path and the rest as the JSON body")
    func postBody() async throws {
        let server = try await RecordingHTTPServer.start()
        let transport = await transport(server, routes: [HTTPTransportRoute(
            toolName: "renamePet", method: .POST, path: "/pets/{petId}/name", pathParams: ["petId"]
        )])

        _ = try await transport.execute(input: TransportInput(
            toolName: "renamePet",
            args: ["petId": AnySendable(7), "name": AnySendable("Rex")]
        ))
        try await server.shutdown()

        let request = try #require(server.requests.first)
        #expect(request.uri == "/pets/7/name")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        #expect(body["name"] as? String == "Rex")
        #expect(body["petId"] == nil)
    }
}
