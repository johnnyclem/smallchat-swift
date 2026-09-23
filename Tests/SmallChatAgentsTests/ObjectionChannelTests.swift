import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SmallChatAgents

/// What stenographer's channel sink posts (delivery.ts `createSinkTransport`).
private let objectionBody = #"""
{"channel":"stenographer","sender":"stenographer","content":"Objection 01OBJ: asserts LOG_BUDGET = 30, tombstoned by TB1","meta":{"kind":"objection","objection_ids":"01OBJ","tb_ids":"TB1","session_ids":"live-1,gone-2","count":"1","bad-key":"x"}}
"""#

@Suite("Channel bridge protocol")
struct ChannelBridgeProtocolTests {
    let secret = "s3cret"

    func post(_ body: String, headers: [(String, String)]) -> ChannelBridgeResponse {
        ChannelBridgeProtocol.handle(
            method: "POST", path: "/event",
            headers: headers.map { (name: $0.0, value: $0.1) },
            body: Data(body.utf8), secret: secret
        )
    }

    @Test("accepts stenographer's objection payload")
    func accepts() throws {
        let response = post(objectionBody, headers: [("x-channel-secret", secret)])
        #expect(response.status == 200)
        let event = try #require(response.event)
        #expect(event.isObjection)
        #expect(event.channel == "stenographer")
        #expect(event.objectionIds == ["01OBJ"])
        #expect(event.tbIds == ["TB1"])
        #expect(event.sessionIds == ["live-1", "gone-2"])
        #expect(event.meta["bad-key"] == nil, "non-identifier meta keys are dropped")
    }

    @Test("bearer auth works; bad or missing secrets are 401")
    func auth() {
        #expect(post(objectionBody, headers: [("Authorization", "Bearer \(secret)")]).status == 200)
        #expect(post(objectionBody, headers: [("X-Channel-Secret", "nope")]).status == 401)
        #expect(post(objectionBody, headers: []).status == 401)
        let open = ChannelBridgeProtocol.handle(method: "POST", path: "/event", headers: [], body: Data(objectionBody.utf8), secret: "")
        #expect(open.status == 401, "an empty configured secret never authenticates")
    }

    @Test("health is open; bad requests are rejected like the TS bridge")
    func errors() {
        let health = ChannelBridgeProtocol.handle(method: "GET", path: "/health", headers: [], body: Data(), secret: secret)
        #expect(health.status == 200)
        let auth = [("X-Channel-Secret", secret)]
        #expect(post("not json", headers: auth).status == 400)
        #expect(post(#"{"meta":{}}"#, headers: auth).status == 400)
        #expect(post(String(repeating: "x", count: ChannelBridgeProtocol.maxBodyBytes + 1), headers: auth).status == 413)
        let unknown = ChannelBridgeProtocol.handle(method: "GET", path: "/sse", headers: auth.map { (name: $0.0, value: $0.1) }, body: Data(), secret: secret)
        #expect(unknown.status == 404)
    }
}

@Suite("Channel bridge server")
struct ChannelBridgeServerTests {
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ChannelInboundEvent] = []
        func add(_ e: ChannelInboundEvent) { lock.lock(); events.append(e); lock.unlock() }
        var all: [ChannelInboundEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    @Test("a real loopback POST reaches the handler")
    func loopback() async throws {
        let received = Received()
        let server = ChannelBridgeServer(port: 0, secret: "k") { received.add($0) }
        let port = try await server.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("k", forHTTPHeaderField: "X-Channel-Secret")
        request.httpBody = Data(objectionBody.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("\"ok\":true"))

        var denied = request
        denied.setValue("wrong", forHTTPHeaderField: "X-Channel-Secret")
        let (_, deniedResponse) = try await URLSession.shared.data(for: denied)
        #expect((deniedResponse as? HTTPURLResponse)?.statusCode == 401)

        await server.stop()
        #expect(received.all.map(\.objectionIds) == [["01OBJ"]])
    }
}

@MainActor
@Suite("Objection routing")
struct ObjectionRoutingTests {
    func makeModel() -> (MessengerModel, MockAgentTransport) {
        let transport = MockAgentTransport()
        let model = MessengerModel(store: MessengerStore(url: nil), transport: transport, scanner: nil)
        model.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "live-1", cwd: "/r/app", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil,
                              live: LiveSessionRecord(pid: 1, sessionId: "live-1", name: "app-live", status: "busy")),
            DiscoveredSession(sessionId: "gone-2", cwd: "/r/lib", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil),
        ])
        return (model, transport)
    }

    func event(_ ids: String = "01OBJ", sessions: String = "live-1,gone-2") -> ChannelInboundEvent {
        ChannelInboundEvent(
            channel: "stenographer", content: "Objection \(ids): LOG_BUDGET = 30",
            meta: ["kind": "objection", "objection_ids": ids, "tb_ids": "TB1", "session_ids": sessions],
            sender: "stenographer"
        )
    }

    @Test("posted to each agent's chats; relayed only into live sessions")
    func routing() async throws {
        let (model, transport) = makeModel()
        let group = try #require(model.createGroup(title: "g", memberIds: ["live-1", "gone-2"]))
        model.handleChannelEvent(event())
        for _ in 0..<20 { await Task.yield() }

        let liveChat = try #require(model.directConversation(with: "live-1"))
        #expect(liveChat.messages.contains { $0.author == .stenographer && $0.citedEntryId == "TB1" })
        #expect(model.conversation(group)?.messages.filter { $0.author == .stenographer }.count == 2)

        #expect(transport.sent.map(\.agentId) == ["live-1"])
        #expect(transport.sent.first?.style == .interrupt)
        #expect(transport.sent.first?.body.contains("LOG_BUDGET = 30") == true)

        let stoppedChat = try #require(model.directConversation(with: "gone-2"))
        #expect(stoppedChat.messages.contains { $0.author == .system && $0.text.contains("isn't running") })

        #expect(model.objections.first?.routedTo == ["live-1", "gone-2"])
        #expect(model.objections.first?.relayedTo == ["live-1"])
    }

    @Test("retries are deduplicated; unknown sessions are kept as unrouted")
    func dedupeAndUnrouted() async {
        let (model, transport) = makeModel()
        model.handleChannelEvent(event())
        model.handleChannelEvent(event())
        for _ in 0..<20 { await Task.yield() }
        #expect(model.objections.count == 1)
        #expect(transport.sent.count == 1)

        model.handleChannelEvent(event("02OBJ", sessions: "nobody"))
        #expect(model.objections.first?.routedTo.isEmpty == true)
    }

    @Test("relay can be switched off")
    func relayOff() async {
        let (model, transport) = makeModel()
        model.settings.relayObjections = false
        model.handleChannelEvent(event())
        for _ in 0..<20 { await Task.yield() }
        #expect(transport.sent.isEmpty)
        #expect(model.directConversation(with: "live-1")?.messages.contains { $0.author == .stenographer } == true)
    }

    @Test("the bridge secret is generated once and persisted")
    func secret() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = MessengerModel(store: MessengerStore(url: url), transport: MockAgentTransport(), scanner: nil)
        #expect(first.settings.objectionChannelSecret.count == 64)
        let second = MessengerModel(store: MessengerStore(url: url), transport: MockAgentTransport(), scanner: nil)
        #expect(second.settings.objectionChannelSecret == first.settings.objectionChannelSecret)
    }
}

@Suite("Settings compatibility")
struct SettingsCompatibilityTests {
    @Test("settings saved by an older build still load (conversations survive)")
    func olderSettings() throws {
        let old = #"""
        {"agents":{},"conversations":[],"stenographerSessions":{},
         "settings":{"wikiPaths":["/w"],"switchboardModel":"haiku","stenographerModel":"sonnet","stenographerWatching":false,"recentDays":7}}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(MessengerSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.settings.wikiPaths == ["/w"])
        #expect(snapshot.settings.stenographerWatching == false)
        #expect(snapshot.settings.recentDays == 7)
        #expect(snapshot.settings.objectionChannelEnabled)
        #expect(snapshot.settings.objectionChannelPort == MessengerSettings.defaultObjectionChannelPort)
    }

    @Test("'all time' (nil recentDays) round-trips")
    func allTime() throws {
        var settings = MessengerSettings()
        settings.recentDays = nil
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MessengerSettings.self, from: data).recentDays == nil)
    }
}
