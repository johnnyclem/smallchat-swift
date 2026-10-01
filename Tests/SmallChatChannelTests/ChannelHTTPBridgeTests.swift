import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SmallChatChannel

private func post(_ url: URL, _ body: String, headers: [String: String]) async throws -> Int {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}

/// `smallchat channel --http-bridge` used to announce a bridge that never
/// listened. ChannelServer now starts one that injects events into the
/// channel.
@Suite("Channel HTTP bridge", .timeLimit(.minutes(1)))
struct ChannelHTTPBridgeTests {

    private func startServer(allowlist: [String]? = nil) async throws -> (ChannelServer, URL) {
        let server = ChannelServer(config: ChannelServerConfig(
            channelName: "webhooks",
            httpBridge: true,
            httpBridgePort: 0,
            httpBridgeSecret: "s3cret",
            senderAllowlist: allowlist
        ))
        await server.start()
        let port = try #require(try await server.startHTTPBridge())
        return (server, URL(string: "http://127.0.0.1:\(port)/event")!)
    }

    @Test("an authenticated POST /event becomes a channel notification")
    func eventInjected() async throws {
        let (server, url) = try await startServer()
        let outbound = await server.outboundMessages

        let status = try await post(url, #"{"content":"deploy finished","meta":{"session_ids":"abc"}}"#,
                                    headers: ["X-Channel-Secret": "s3cret"])
        #expect(status == 200)

        var iterator = outbound.makeAsyncIterator()
        let line = try #require(await iterator.next())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["method"] as? String == "notifications/claude/channel")
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["content"] as? String == "deploy finished")
        #expect(params["channel"] as? String == "webhooks")
        #expect((params["meta"] as? [String: Any])?["session_ids"] as? String == "abc")

        await server.shutdown()
    }

    @Test("the secret is required, and a rejected sender is 403")
    func authAndGating() async throws {
        let (server, url) = try await startServer(allowlist: ["alice"])

        #expect(try await post(url, #"{"content":"x"}"#, headers: [:]) == 401)
        #expect(try await post(url, #"{"content":"x"}"#, headers: ["Authorization": "Bearer wrong"]) == 401)
        #expect(try await post(url, #"{"content":"x","sender":"mallory"}"#, headers: ["Authorization": "Bearer s3cret"]) == 403)
        #expect(try await post(url, #"{"content":"x","sender":"alice"}"#, headers: ["Authorization": "Bearer s3cret"]) == 200)

        await server.shutdown()
    }

    @Test("a bridge without a secret does not start")
    func secretMandatory() async {
        let server = ChannelServer(config: ChannelServerConfig(channelName: "c", httpBridge: true, httpBridgePort: 0))
        await #expect(throws: ChannelBridgeError.self) {
            _ = try await server.startHTTPBridge()
        }
    }

    @Test("no bridge unless configured")
    func notConfigured() async throws {
        let server = ChannelServer(config: ChannelServerConfig(channelName: "c"))
        #expect(try await server.startHTTPBridge() == nil)
    }
}

@Suite("Channel server protocol version")
struct ChannelProtocolVersionTests {

    private func negotiated(_ requested: String) async throws -> String? {
        let server = ChannelServer(config: ChannelServerConfig(channelName: "test"))
        await server.start()
        let outbound = await server.outboundMessages
        await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)"}}"#)
        var iterator = outbound.makeAsyncIterator()
        let line = try #require(await iterator.next())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        await server.shutdown()
        return (json["result"] as? [String: Any])?["protocolVersion"] as? String
    }

    @Test("a supported version is echoed; others get the newest")
    func negotiation() async throws {
        #expect(try await negotiated("2025-06-18") == "2025-06-18")
        #expect(try await negotiated("2024-11-05") == "2024-11-05")
        #expect(try await negotiated("2025-03-26") == "2025-11-25")
        #expect(try await negotiated("1999-01-01") == "2025-11-25")
    }
}
