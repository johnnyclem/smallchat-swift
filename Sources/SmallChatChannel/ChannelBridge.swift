import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - Channel bridge
//
// An HTTP endpoint that speaks smallchat's channel-bridge contract (the TS
// `ChannelServer` HTTP bridge):
//
//   POST /event   {content, meta?, timestamp?}
//                 authenticated by `X-Channel-Secret` (or `Authorization: Bearer`);
//                 the secret is mandatory
//   GET  /health  liveness, unauthenticated
//
// Provenance comes from the server, never from the body (the TS bridge's
// rule, SC-SURF-10): every event is from the identity the secret
// authenticates (`secretIdentity`, "bridge" unless configured) on the
// configured channel (`defaultChannel`). A body's `sender` and `channel` are
// ignored, and meta can't set `sender`, `source` or `user`
// (`reservedMetaKeys`), so a poster can't present itself as someone the
// sender gate admits, or forge the `<channel>` tag's provenance.
//
// Two users: `smallchat channel --http-bridge` injects each event into the
// Claude Code channel (403 when sender gating or the size limit rejects it),
// and the messenger (SmallChatAgents) receives stenographer's
// `--objection-channel` posts. Stenographer posts each objection as it's
// raised with `meta.kind = "objection"` and the offending Claude Code session
// ids in `meta.session_ids`; the messenger routes it to those agents' chats
// and relays it into the live session. Agent-drafted tombstones arrive as
// `meta.kind = "proposal"` and wait for the user to notarize them.

/// One event posted to the bridge.
public struct ChannelInboundEvent: Sendable, Equatable {
    /// The bridge's configured channel (a body's `channel` is ignored).
    public let channel: String
    public let content: String
    /// The posted meta, without keys a channel tag can't carry or a poster
    /// may not set (`isValidMetaKey`).
    public let meta: [String: String]
    /// Who posted it: the identity of the credential the request presented
    /// (a body's `sender` is ignored). Nil only on an event built in code.
    public let sender: String?
    public let timestamp: String?

    public init(channel: String, content: String, meta: [String: String] = [:], sender: String? = nil, timestamp: String? = nil) {
        self.channel = channel
        self.content = content
        self.meta = meta
        self.sender = sender
        self.timestamp = timestamp
    }

    public var isObjection: Bool { meta["kind"] == "objection" }
    /// An agent-drafted tombstone stenographer raised for the user to notarize.
    public var isProposal: Bool { meta["kind"] == "proposal" }
    public var proposalId: String? { meta["proposal_id"].flatMap { $0.isEmpty ? nil : $0 } }
    public var draftedBy: String? { meta["drafted_by"] }
    /// Where the poster says stenographer takes the approval
    /// (`POST …/proposals/:id/notarize`). Untrusted event data: the messenger
    /// ignores it and builds the URL from its own settings.
    public var notarizeURL: URL? { meta["notarize_url"].flatMap(URL.init(string:)) }

    func list(_ key: String) -> [String] {
        (meta[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Claude Code session ids the event concerns.
    public var sessionIds: [String] { list("session_ids") }
    public var objectionIds: [String] { list("objection_ids") }
    public var tbIds: [String] { list("tb_ids") }
}

public struct ChannelBridgeResponse: Sendable, Equatable {
    public let status: Int
    public let body: String
    /// Set when the request carried an accepted event.
    public let event: ChannelInboundEvent?
}

public enum ChannelBridgeProtocol {
    /// Objections are compact; anything bigger is rejected (TS: payload cap).
    public static let maxBodyBytes = 64 * 1024
    public static let defaultChannel = "smallchat"
    /// Who a request presenting the shared secret is, unless configured (as the TS bridge's default).
    public static let defaultSecretIdentity = "bridge"

    /// Pure request handling, so the contract is testable without sockets.
    /// An accepted event is from `secretIdentity`, the identity the secret
    /// authenticates, on `defaultChannel`: the body's `sender` and `channel`
    /// are ignored.
    public static func handle(
        method: String,
        path: String,
        headers: [(name: String, value: String)],
        body: Data,
        secret: String,
        secretIdentity: String = ChannelBridgeProtocol.defaultSecretIdentity,
        defaultChannel: String = ChannelBridgeProtocol.defaultChannel
    ) -> ChannelBridgeResponse {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        if method == "GET", route == "/health" {
            return json(200, ["status": "ok", "channel": defaultChannel])
        }

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let provided = header("X-Channel-Secret")
            ?? header("Authorization").map { value in
                value.range(of: "Bearer ", options: [.caseInsensitive, .anchored]).map { String(value[$0.upperBound...]) } ?? value
            }
        guard !secret.isEmpty, let provided, constantTimeEqual(provided, secret) else {
            return json(401, ["error": "Unauthorized"])
        }

        guard method == "POST", route == "/event" else {
            return json(404, ["error": "Not found"])
        }
        guard body.count <= maxBodyBytes else {
            return json(413, ["error": "Payload too large"])
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return json(400, ["error": "Invalid JSON"])
        }
        guard let content = payload["content"] as? String, !content.isEmpty else {
            return json(400, ["error": "Missing or invalid \"content\" field"])
        }
        var meta: [String: String] = [:]
        for (key, value) in payload["meta"] as? [String: Any] ?? [:] {
            // Channel meta keys are identifier-only (Claude Code drops others), and
            // never one that names who sent the event or where it came from.
            guard isValidMetaKey(key) else { continue }
            if let s = value as? String { meta[key] = s } else if let n = value as? NSNumber { meta[key] = n.stringValue }
        }
        // Provenance comes from the server: the configured channel and the
        // secret's identity. The body's "channel" and "sender" are ignored.
        let event = ChannelInboundEvent(
            channel: defaultChannel,
            content: content,
            meta: meta,
            sender: secretIdentity,
            timestamp: payload["timestamp"] as? String
        )
        return ChannelBridgeResponse(
            status: 200,
            body: encode(["ok": true, "channel": defaultChannel, "sender": secretIdentity]),
            event: event
        )
    }

    /// A fresh random secret for the bridge (hex, 32 bytes of entropy).
    public static func generateSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// Compare a caller-supplied secret with the expected one. Strings of
    /// different lengths never match (the length is not secret); for equal
    /// lengths the time taken does not depend on where they differ.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count {
            diff |= x[i] ^ y[i]
        }
        return diff == 0
    }

    static func json(_ status: Int, _ object: [String: Any]) -> ChannelBridgeResponse {
        ChannelBridgeResponse(status: status, body: encode(object), event: nil)
    }

    static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Server

/// HTTP server for the bridge. Binds 127.0.0.1 unless told otherwise:
/// events can carry transcript lines.
public final class ChannelBridgeServer: @unchecked Sendable {
    public let port: Int
    public let host: String
    private let secret: String
    private let secretIdentity: String
    private let defaultChannel: String
    private let accept: @Sendable (ChannelInboundEvent) async -> Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    /// A bridge whose events are all accepted (answered `200`). Each event is
    /// from `secretIdentity` on `defaultChannel`, whatever its body says.
    public convenience init(
        port: Int,
        secret: String,
        secretIdentity: String = ChannelBridgeProtocol.defaultSecretIdentity,
        defaultChannel: String = ChannelBridgeProtocol.defaultChannel,
        onEvent: @escaping @Sendable (ChannelInboundEvent) -> Void
    ) {
        self.init(port: port, secret: secret, secretIdentity: secretIdentity, defaultChannel: defaultChannel) { event in
            onEvent(event)
            return true
        }
    }

    /// A bridge that answers `200` when `accept` takes the event and `403`
    /// when it refuses it. Each event is from `secretIdentity` (the identity
    /// the secret authenticates) on `defaultChannel`, whatever its body says.
    public init(
        host: String = "127.0.0.1",
        port: Int,
        secret: String,
        secretIdentity: String = ChannelBridgeProtocol.defaultSecretIdentity,
        defaultChannel: String = ChannelBridgeProtocol.defaultChannel,
        accept: @escaping @Sendable (ChannelInboundEvent) async -> Bool
    ) {
        self.host = host
        self.port = port
        self.secret = secret
        self.secretIdentity = secretIdentity
        self.defaultChannel = defaultChannel
        self.accept = accept
    }

    /// Start listening. Returns the bound port (useful when `port` is 0).
    @discardableResult
    public func start() async throws -> Int {
        let secret = self.secret
        let secretIdentity = self.secretIdentity
        let defaultChannel = self.defaultChannel
        let accept = self.accept
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        BridgeHTTPHandler(secret: secret, secretIdentity: secretIdentity, defaultChannel: defaultChannel, accept: accept)
                    )
                }
            }
        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
        try? await group.shutdownGracefully()
    }
}

private final class BridgeHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let secret: String
    private let secretIdentity: String
    private let defaultChannel: String
    private let accept: @Sendable (ChannelInboundEvent) async -> Bool
    private var head: HTTPRequestHead?
    private var body = Data()
    private var tooLarge = false

    init(secret: String, secretIdentity: String, defaultChannel: String, accept: @escaping @Sendable (ChannelInboundEvent) async -> Bool) {
        self.secret = secret
        self.secretIdentity = secretIdentity
        self.defaultChannel = defaultChannel
        self.accept = accept
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
            tooLarge = false
        case .body(var buffer):
            if body.count + buffer.readableBytes > ChannelBridgeProtocol.maxBodyBytes {
                tooLarge = true
            } else if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let response: ChannelBridgeResponse
            if tooLarge {
                response = ChannelBridgeProtocol.json(413, ["error": "Payload too large"])
            } else {
                response = ChannelBridgeProtocol.handle(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: head.headers.map { ($0.name, $0.value) },
                    body: body,
                    secret: secret,
                    secretIdentity: secretIdentity,
                    defaultChannel: defaultChannel
                )
            }
            guard let event = response.event else {
                write(response, keepAlive: head.isKeepAlive, context: context)
                return
            }
            // Deliver the event off the event loop, then hop back to answer:
            // the context is only touched on its event loop.
            let keepAlive = head.isKeepAlive
            let loop = context.eventLoop
            let bound = NIOLoopBound((handler: self, context: context), eventLoop: loop)
            let accept = self.accept
            Task {
                let accepted = await accept(event)
                loop.execute {
                    let (handler, context) = bound.value
                    handler.write(
                        accepted ? response : ChannelBridgeProtocol.json(403, ["error": "Event rejected (sender gating or payload size)"]),
                        keepAlive: keepAlive,
                        context: context
                    )
                }
            }
        }
    }

    private func write(_ response: ChannelBridgeResponse, keepAlive: Bool, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(response.body.utf8.count))
        if !keepAlive { headers.add(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
        buffer.writeString(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive {
            let channel = context.channel
            done.whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
