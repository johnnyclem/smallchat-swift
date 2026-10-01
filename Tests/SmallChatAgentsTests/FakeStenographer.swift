import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SmallChatCore
@testable import SmallChatTruth

// MARK: - Fake stenographer REST API

/// Loopback stand-in for stenographer's proposal routes (release plan,
/// Addendum D), written against that contract:
///
///   POST /proposals               one PROPOSAL envelope → 201 {proposalId}; 200 when this id was filed before
///   POST /proposals/:id/notarize  {notary} → 200 with the minted TB entry
///
/// Both need `X-Notary-Secret` and `Authorization: Bearer` (401 otherwise).
/// The envelope is read with SmallChatTruth's codec (its hash is checked),
/// and a notary who drafted the proposal is refused (422), as stenographer
/// refuses it (contempt of corpus).
final class FakeStenographer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    let notarySecret: String
    let restToken: String
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel!
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var filed: [String: (proposalId: String, line: [String: AnyCodableValue])] = [:]
    private var notarized: Set<String> = []
    private var _failNotarize: (status: Int, error: String)?
    /// Answer every notarize request with this status and error, when set.
    var failNotarize: (status: Int, error: String)? {
        get { lock.withLock { _failNotarize } }
        set { lock.withLock { _failNotarize = newValue } }
    }

    var port: Int { channel.localAddress!.port! }
    var requests: [Request] { lock.withLock { _requests } }

    private init(notarySecret: String, restToken: String) {
        self.notarySecret = notarySecret
        self.restToken = restToken
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    static func start(notarySecret: String, restToken: String) async throws -> FakeStenographer {
        let fake = FakeStenographer(notarySecret: notarySecret, restToken: restToken)
        fake.channel = try await ServerBootstrap(group: fake.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(FakeStenographerHandler(fake: fake))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return fake
    }

    func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }

    /// The JSON reply to one request: status and body.
    func respond(to request: Request) -> (Int, String) {
        lock.withLock { _requests.append(request) }
        guard request.headers["authorization"] == "Bearer \(restToken)" else { return (401, #"{"error":"missing or invalid bearer token"}"#) }
        guard request.method == "POST" else { return (405, #"{"error":"Method not allowed"}"#) }
        guard request.headers["x-notary-secret"] == notarySecret else { return (401, #"{"error":"invalid or missing notary secret"}"#) }

        if request.path == "/proposals" {
            let text = String(decoding: request.body, as: UTF8.self)
            let decoded: DecodedTruthLine
            do {
                decoded = try TruthFormat.decode(text)
            } catch {
                return (400, "{\"error\":\(jsonQuoted("Invalid PROPOSAL envelope — \(error)"))}")
            }
            guard decoded.type == .proposal else { return (400, #"{"error":"Invalid PROPOSAL envelope — not a PROPOSAL"}"#) }
            var envelope = decoded.object
            for key in ["seq", "prevHash", "hash"] { envelope.removeValue(forKey: key) }
            return lock.withLock {
                if let prior = filed[decoded.id] {
                    guard prior.line == envelope else {
                        return (409, "{\"error\":\"already filed with different content\",\"proposalId\":\"\(prior.proposalId)\"}")
                    }
                    return (200, "{\"proposalId\":\"\(prior.proposalId)\"}")
                }
                let proposalId = "01PROPOSAL\(String(format: "%016d", filed.count + 1))"
                filed[decoded.id] = (proposalId, envelope)
                return (201, "{\"proposalId\":\"\(proposalId)\"}")
            }
        }

        let parts = request.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "proposals", parts[2] == "notarize" else { return (404, #"{"error":"not found"}"#) }
        if let failNotarize { return (failNotarize.status, "{\"error\":\(jsonQuoted(failNotarize.error))}") }
        let proposalId = String(parts[1])
        guard case .dict(let body)? = try? parseJSON(request.body), case .string(let notary)? = body["notary"] else {
            return (400, #"{"error":"notary is required"}"#)
        }
        return lock.withLock {
            guard let envelope = filed.values.first(where: { $0.proposalId == proposalId })?.line else {
                return (422, #"{"error":"no such proposal"}"#)
            }
            guard !notarized.contains(proposalId) else { return (422, "{\"error\":\"proposal \(proposalId) is already signed\"}") }
            guard case .string(let author)? = envelope["author"], identityKey(author) != identityKey(notary) else {
                return (422, #"{"error":"contempt of corpus: the notary already stands behind this proposal"}"#)
            }
            guard case .dict(let draft)? = envelope["draft"] else { return (422, #"{"error":"no draft"}"#) }
            notarized.insert(proposalId)
            let mintedId = "01MINTED\(String(format: "%018d", notarized.count))"
            var minted = draft
            minted["signedBy"] = .string(notary)
            minted["status"] = .string("active")
            let entry: AnyCodableValue = .dict([
                "id": .string(mintedId),
                "type": .string("TB"),
                "author": .string(notary),
                "createdAt": .string("2026-10-01T12:00:00.000Z"),
                "body": .dict(minted),
                "links": .array([.dict(["fromId": .string(mintedId), "toId": .string(proposalId), "type": .string("signs")])]),
            ])
            return (200, (try? canonicalJSON(entry)) ?? "{}")
        }
    }
}

private final class FakeStenographerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let fake: FakeStenographer
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(fake: FakeStenographer) {
        self.fake = fake
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
            var headers: [String: String] = [:]
            for (name, value) in head.headers { headers[name.lowercased()] = value }
            let request = FakeStenographer.Request(
                method: head.method.rawValue,
                path: String(head.uri.split(separator: "?").first ?? ""),
                headers: headers,
                body: Data(body.readableBytesView)
            )
            let (status, text) = fake.respond(to: request)
            var responseHeaders = HTTPHeaders()
            responseHeaders.add(name: "Content-Type", value: "application/json; charset=utf-8")
            responseHeaders.add(name: "Content-Length", value: String(text.utf8.count))
            responseHeaders.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: responseHeaders))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
        }
    }
}
