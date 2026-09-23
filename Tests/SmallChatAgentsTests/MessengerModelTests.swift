import Foundation
import Testing
@testable import SmallChatAgents
@testable import SmallChatTruth

@Suite("Stenographer")
struct StenographerTests {
    static let tb = TruthTbEntry(
        id: "TB1", ts: "2026-09-18T10:00:00Z", author: "johnny",
        claim: "LOG_BUDGET was raised from 30 to 100.",
        evidence: [TruthEvidence(kind: .commit, ref: "abc")], signedBy: "johnny", status: .active,
        literals: [TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100")]
    )
    static let uv = TruthUvEntry(
        id: "UV1", ts: "2026-09-18T11:00:00Z", author: "sam",
        assertion: "The embedder cache is safe to share across worker threads.",
        basis: "No crash in soak testing.", verifyBy: TruthVerifyBy(kind: .command, value: "npm test -- embedding"),
        contests: nil, status: .open
    )
    static let ledger = TruthLedgerSnapshot(entries: [.tb(tb), .uv(uv)])

    @Test("objects to a tombstoned literal near its subject")
    func objection() {
        let notes = Stenographer.observe("I'll set logBudget = 30 for now", ledger: Self.ledger)
        #expect(notes.count == 1)
        #expect(notes[0].kind == .objection)
        #expect(notes[0].entryId == "TB1")
        #expect(notes[0].text.contains("current value is 100"))
    }

    @Test("stays quiet when the line discusses the change or lacks the subject")
    func noObjection() {
        #expect(Stenographer.observe("bumped LOG_BUDGET from 30 to 100", ledger: Self.ledger).isEmpty)
        #expect(Stenographer.observe("retry 30 times", ledger: Self.ledger).isEmpty)
        #expect(Stenographer.observe("LOG_BUDGET = 300", ledger: Self.ledger).isEmpty)
    }

    @Test("flags reliance on an open unverified claim")
    func unverified() {
        let notes = Stenographer.observe("Since the embedder cache is shared across worker threads safely, skip the lock.", ledger: Self.ledger)
        #expect(notes.map(\.kind) == [.unverified])
        #expect(notes[0].text.contains("UNVERIFIED"))
    }

    @Test("brief preloads the ledger")
    func brief() {
        let brief = Stenographer.brief(ledger: Self.ledger)
        #expect(brief.contains("LOG_BUDGET was raised"))
        #expect(brief.contains("[UV — UNVERIFIED]"))
    }

    @Test("wiki literals round-trip through the Swift codec")
    func literalsRoundTrip() throws {
        let line = #"{"author":"johnny","claim":"c","evidence":[],"id":"TB9","literals":[{"current":"100","dead":"30","subject":"LOG_BUDGET"}],"signedBy":"johnny","status":"active","ts":"t","type":"TB"}"#
        let parsed = TruthWiki.parse(lines: [line])
        #expect(parsed.errors.isEmpty)
        guard case .tb(let tb) = parsed.entries.first else { Issue.record("not a TB"); return }
        #expect(tb.literals == [TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100")])
        #expect(TruthWiki.serialize(parsed.entries) == [line])
    }
}

@MainActor
@Suite("Messenger model")
struct MessengerModelTests {
    func makeModel(transport: MockAgentTransport = MockAgentTransport()) -> (MessengerModel, MockAgentTransport) {
        let model = MessengerModel(store: MessengerStore(url: nil), transport: transport, scanner: nil)
        let now = Date()
        model.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "aaaa-1", cwd: "/r/instrument", gitBranch: nil, title: nil, lastActivity: now,
                              transcriptPath: nil, live: nil),
            DiscoveredSession(sessionId: "bbbb-2", cwd: "/r/llm-wiki", gitBranch: nil, title: nil, lastActivity: now,
                              transcriptPath: nil, live: LiveSessionRecord(pid: 1, sessionId: "bbbb-2", kind: "background",
                                                                           name: "wiki-bot", status: "busy")),
        ])
        return (model, transport)
    }

    /// Let spawned delivery tasks run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("discovered sessions get durable handles and live status")
    func handles() {
        let (model, _) = makeModel()
        #expect(model.agents.map(\.handle) == ["llm-wiki-bb", "instrument-aa"])
        #expect(model.agents[0].activity == .busy)
        #expect(model.agents[0].kind == .background)
        #expect(model.agents[0].claudeName == "wiki-bot")
    }

    @Test("rename validates, updates the direct chat title, and persists")
    func rename() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("messenger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = MessengerModel(store: MessengerStore(url: url), transport: MockAgentTransport(), scanner: nil)
        model.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "aaaa-1", cwd: "/r/instrument", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil),
            DiscoveredSession(sessionId: "bbbb-2", cwd: "/r/other", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil),
        ])
        let conversationId = try #require(model.openDirect(agentId: "aaaa-1"))
        try model.rename(agentId: "aaaa-1", to: "Compat-Guard")
        #expect(model.agent("aaaa-1")?.handle == "compat-guard")
        #expect(model.conversation(conversationId)?.title == "compat-guard")
        #expect(throws: HandleError.taken("compat-guard")) { try model.rename(agentId: "bbbb-2", to: "compat-guard") }

        // A fresh model on the same store keeps the name.
        let reloaded = MessengerModel(store: MessengerStore(url: url), transport: MockAgentTransport(), scanner: nil)
        reloaded.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "aaaa-1", cwd: "/r/instrument", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil),
        ])
        #expect(reloaded.agent("aaaa-1")?.handle == "compat-guard")
    }

    @Test("direct chat: reply is visible and needs no share decision")
    func direct() async throws {
        let (model, transport) = makeModel()
        let id = try #require(model.openDirect(agentId: "aaaa-1"))
        model.send("run the tests", in: id)
        await settle()
        let messages = try #require(model.conversation(id)).messages
        #expect(messages.map(\.author) == [.user, .agent("aaaa-1")])
        #expect(messages[1].visibility == .group)
        #expect(!messages[1].awaitingShareDecision)
        #expect(transport.sent.first?.body.contains("you are @instrument-aa") == true)
    }

    @Test("group: fan out, private reply, share interrupts the others")
    func groupShare() async throws {
        let transport = MockAgentTransport { body, agent in
            agent.id == "aaaa-1" ? "found the bug" : nil  // bbbb-2 is live: replies later
        }
        let (model, _) = makeModel(transport: transport)
        let id = try #require(model.createGroup(title: "compat", memberIds: ["aaaa-1", "bbbb-2"]))
        model.send("what broke?", in: id)
        await settle()

        #expect(Set(transport.sent.map(\.agentId)) == ["aaaa-1", "bbbb-2"])
        #expect(model.awaiting[id] == ["bbbb-2"], "live agent still owes a reply")

        let reply = try #require(model.conversation(id)?.messages.first { $0.author == .agent("aaaa-1") })
        #expect(reply.visibility == .privateToUser)
        #expect(reply.awaitingShareDecision)

        model.share(messageId: reply.id, in: id)
        await settle()
        let interrupt = try #require(transport.sent.last)
        #expect(interrupt.agentId == "bbbb-2")
        #expect(interrupt.style == .interrupt)
        #expect(interrupt.body.contains("@instrument-aa shared this with the group"))
        #expect(interrupt.body.hasSuffix("found the bug"))
        let shared = try #require(model.conversation(id)?.messages.first { $0.id == reply.id })
        #expect(shared.visibility == .group && shared.shareDecided)

        // The live agent answers through the switchboard, by its Claude Code name.
        transport.deliverInbound(InboundReply(senderName: "wiki-bot", text: "ack"))
        await settle()
        let late = try #require(model.conversation(id)?.messages.last { $0.author == .agent("bbbb-2") })
        #expect(late.text == "ack")
        #expect(late.visibility == .privateToUser)
        #expect(model.awaiting[id] == nil)
    }

    @Test("keep private closes the decision without sending")
    func keepPrivate() async throws {
        let (model, transport) = makeModel()
        let id = try #require(model.createGroup(title: "", memberIds: ["aaaa-1", "bbbb-2"]))
        #expect(model.conversation(id)?.title == "instrument-aa, llm-wiki-bb")
        model.send("@instrument-aa only you", in: id)
        await settle()
        #expect(transport.sent.map(\.agentId) == ["aaaa-1"])
        let reply = try #require(model.conversation(id)?.messages.first { $0.awaitingShareDecision })
        model.keepPrivate(messageId: reply.id, in: id)
        #expect(model.conversation(id)?.messages.contains { $0.awaitingShareDecision } == false)
        #expect(transport.sent.count == 1)
    }

    @Test("unknown mentions are reported, stenographer answers @stenographer")
    func stenographerAndUnknown() async throws {
        let (model, transport) = makeModel()
        let id = try #require(model.openDirect(agentId: "aaaa-1"))
        model.send("@ghost hi", in: id)
        model.send("@stenographer what's tombstoned?", in: id)
        await settle()
        #expect(transport.sent.isEmpty)
        let messages = try #require(model.conversation(id)).messages
        #expect(messages.contains { $0.author == .system && $0.text.contains("@ghost") })
        #expect(messages.contains { $0.author == .stenographer && $0.text == "On the record." })
    }

    @Test("archiving hides an agent from the list")
    func archive() {
        let (model, _) = makeModel()
        model.setArchived(agentId: "aaaa-1", true)
        #expect(!model.agents.contains { $0.id == "aaaa-1" })
        #expect(model.archivedAgents.map(\.id) == ["aaaa-1"])
        model.setArchived(agentId: "aaaa-1", false)
        #expect(model.agents.contains { $0.id == "aaaa-1" })
    }

    @Test("new agent: session id adopted, chat opened")
    func startAgent() async throws {
        let (model, _) = makeModel()
        try model.startAgent(handle: "scout", cwd: "/r/new", prompt: "map the repo")
        await settle()
        let agent = try #require(model.agent(handle: "scout"))
        #expect(agent.id == "mock-scout")
        let conversation = try #require(model.directConversation(with: agent.id))
        #expect(conversation.messages.map(\.author) == [.user, .agent("mock-scout")])
        #expect(model.selectedConversationId == conversation.id)
        #expect(throws: HandleError.taken("scout")) { try model.startAgent(handle: "scout", cwd: "/r", prompt: "x") }
    }
}

@MainActor
@Suite("Live refresh")
struct LiveRefreshTests {
    @Test("registry poll flips status without a full scan")
    func poll() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-live-\(UUID().uuidString)")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var scanner = ClaudeSessionScanner(claudeHome: home)
        scanner.isProcessAlive = { _ in true }
        let model = MessengerModel(store: MessengerStore(url: nil), transport: MockAgentTransport(), scanner: scanner)
        await model.refresh()
        #expect(model.agents.isEmpty)

        try #"{"pid":7,"sessionId":"cccc-3","cwd":"/r/new","kind":"interactive","name":"n","status":"idle"}"#
            .write(to: sessions.appendingPathComponent("7.json"), atomically: true, encoding: .utf8)
        await model.refreshLive()
        #expect(model.agents.map(\.handle) == ["new-cc"])
        #expect(model.agents.first?.activity == .idle)

        try FileManager.default.removeItem(at: sessions.appendingPathComponent("7.json"))
        await model.refreshLive()
        #expect(model.agent("cccc-3")?.activity == .stopped)
    }

    @Test("missing CLI fails sends with a helpful error")
    func unavailable() async {
        let model = MessengerModel(store: MessengerStore(url: nil), transport: UnavailableTransport(), scanner: nil)
        model.rebuildAgents(discovered: [DiscoveredSession(sessionId: "a1", cwd: "/r/x", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil)])
        let id = model.openDirect(agentId: "a1")!
        model.send("hi", in: id)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.conversation(id)?.messages.last?.text.contains("Couldn't find the `claude` CLI") == true)
        #expect(model.awaiting[id] == nil)
    }
}

@MainActor
@Suite("Inbound routing")
struct InboundRoutingTests {
    @Test("an unsolicited reply lands in the agent's direct chat without stealing focus")
    func unsolicited() async throws {
        let transport = MockAgentTransport()
        let model = MessengerModel(store: MessengerStore(url: nil), transport: transport, scanner: nil)
        model.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "a1", cwd: "/r/x", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil,
                              live: LiveSessionRecord(pid: 1, sessionId: "a1", name: "xname", status: "idle")),
            DiscoveredSession(sessionId: "b2", cwd: "/r/y", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil),
        ])
        let focused = try #require(model.openDirect(agentId: "b2"))
        transport.deliverInbound(InboundReply(senderName: "xname", text: "heads up"))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.selectedConversationId == focused)
        #expect(model.directConversation(with: "a1")?.messages.map(\.text) == ["heads up"])
    }
}
