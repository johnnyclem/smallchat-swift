import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SmallChatTransport

// MARK: - Gated SSE server

/// Loopback HTTP server that answers every request with an SSE response: it
/// writes `head` events at once, then holds the response open until `release()`
/// is called, then writes `tail` events and ends the response.
///
/// A client that buffers the whole body before yielding (instead of streaming)
/// never sees the `head` events while the gate is closed.
final class GatedSSEServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let gate: EventLoopPromise<Void>

    var baseURL: URL { URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)")! }

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, gate: EventLoopPromise<Void>) {
        self.group = group
        self.channel = channel
        self.gate = gate
    }

    static func start(head: [String], tail: [String]) async throws -> GatedSSEServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let gate = group.next().makePromise(of: Void.self)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        GatedSSEHandler(head: head, tail: tail, gate: gate.futureResult)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return GatedSSEServer(group: group, channel: channel, gate: gate)
    }

    /// Lets every held response finish. Idempotent.
    func release() {
        gate.futureResult.eventLoop.execute { [gate] in gate.succeed(()) }
    }

    func shutdown() async throws {
        release()
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

private final class GatedSSEHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let head: [String]
    private let tail: [String]
    private let gate: EventLoopFuture<Void>

    init(head: [String], tail: [String], gate: EventLoopFuture<Void>) {
        self.head = head
        self.tail = tail
        self.gate = gate
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))),
            promise: nil
        )
        for event in head {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "data: \(event)\n\n")))), promise: nil)
        }
        context.flush()

        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let tail = self.tail
        gate.hop(to: context.eventLoop).whenSuccess {
            let context = bound.value
            for event in tail {
                let part = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "data: \(event)\n\n")))
                context.write(NIOAny(part), promise: nil)
            }
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }
}

// MARK: - Helpers

/// Drains `stream`, opening the server gate once the first output has arrived.
/// Returns `nil` if the stream does not finish within `timeout`.
private func collectReleasingAfterFirst(
    _ stream: AsyncThrowingStream<TransportOutput, Error>,
    server: GatedSSEServer,
    timeout: Duration = .seconds(10)
) async throws -> [TransportOutput]? {
    try await withThrowingTaskGroup(of: [TransportOutput]?.self) { group in
        group.addTask {
            var outputs: [TransportOutput] = []
            for try await output in stream {
                outputs.append(output)
                if outputs.count == 1 { server.release() }
            }
            return outputs
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        server.release()
        return result
    }
}

// MARK: - Tests

/// Streaming responses must be yielded as bytes arrive on every platform. On
/// Linux, swift-corelibs-foundation has no `URLSession.bytes(for:)`, so the
/// transports used to fail to compile there.
@Suite("Streaming response bodies")
struct StreamingBodyTests {

    @Test("HTTPTransport.executeStream yields SSE events before the response ends")
    func httpTransportStreamsIncrementally() async throws {
        let server = try await GatedSSEServer.start(head: ["first"], tail: ["second"])
        let transport = HTTPTransport(config: TransportConfig(baseURL: server.baseURL, timeout: 15))

        let outputs = try await collectReleasingAfterFirst(
            transport.executeStream(input: TransportInput(toolName: "events")),
            server: server
        )
        try await server.shutdown()

        let bodies = try #require(outputs, "first SSE event was not delivered while the response was still open")
            .map { $0.bodyString ?? "" }
        #expect(bodies == ["first", "second"])
    }

    @Test("HTTPTransport.execute returns the complete body")
    func httpTransportExecuteReturnsBody() async throws {
        let server = try await GatedSSEServer.start(head: ["first"], tail: ["second"])
        server.release()
        let transport = HTTPTransport(config: TransportConfig(baseURL: server.baseURL, timeout: 15))

        let output = try await transport.execute(input: TransportInput(toolName: "events"))
        try await server.shutdown()

        #expect(output.statusCode == 200)
        #expect(output.bodyString == "data: first\n\ndata: second\n\n")
        #expect(output.headers.contains { $0.key.lowercased() == "content-type" && $0.value == "text/event-stream" })
    }

    @Test("MCPSSETransport.executeStream yields notifications before the result")
    func mcpSSETransportStreamsIncrementally() async throws {
        let progress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#
        let result = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        let server = try await GatedSSEServer.start(head: [progress], tail: [result])
        let transport = MCPSSETransport(config: MCPSSEConfig(url: server.baseURL.appendingPathComponent("mcp")))

        let outputs = try await collectReleasingAfterFirst(
            transport.executeStream(input: TransportInput(toolName: "echo")),
            server: server
        )
        try await server.shutdown()

        let collected = try #require(outputs, "progress notification was not delivered while the response was still open")
        #expect(collected.count == 2)
        #expect(collected.first?.metadata["streaming"] == "true")
        #expect(collected.first?.bodyString == #"{"progress":1}"#)
        #expect(collected.last?.bodyString == #"{"ok":true}"#)
    }
}
