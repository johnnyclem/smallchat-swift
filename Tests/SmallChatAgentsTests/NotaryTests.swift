import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SmallChatAgents

/// What stenographer's `raiseForNotarization` posts to the channel bridge.
private func proposalEvent(_ id: String = "01PROP", sessions: String = "live-1") -> ChannelInboundEvent {
    ChannelInboundEvent(
        channel: "stenographer",
        content: "✍️ claude-code:@app drafted a tombstone for your approval (\(id)): LOG_BUDGET 30 is dead",
        meta: [
            "kind": "proposal", "proposal_id": id, "drafted_by": "claude-code:@app",
            "session_ids": sessions, "notarize_url": "http://127.0.0.1:8787/proposals/\(id)/notarize",
        ],
        sender: "stenographer"
    )
}

@Suite("Notary client")
struct NotaryClientTests {
    let notarize = URL(string: "http://127.0.0.1:8787/proposals/01PROP/notarize")!

    @Test("proposal events expose what the inbox needs")
    func parsesEvent() {
        let event = proposalEvent()
        #expect(event.isProposal)
        #expect(!event.isObjection)
        #expect(event.proposalId == "01PROP")
        #expect(event.draftedBy == "claude-code:@app")
        #expect(event.notarizeURL == notarize)
        #expect(event.sessionIds == ["live-1"])
    }

    @Test("approving posts the notary to …/notarize with the secret")
    func approveRequest() throws {
        let request = try NotaryClient.request(for: .approve(notary: "johnny"), notarizeURL: notarize, secret: "s3cret")
        #expect(request.url == notarize)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Notary-Secret") == "s3cret")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["notary": "johnny"])
    }

    @Test("declining posts to the sibling …/dismiss with a reason")
    func declineRequest() throws {
        let request = try NotaryClient.request(for: .decline(by: "johnny", reason: "still 30 in prod"), notarizeURL: notarize, secret: "s3cret")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/proposals/01PROP/dismiss")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["dismissedBy": "johnny", "reason": "still 30 in prod"])
    }

    @Test("the inbox keeps only open agent drafts")
    func parsesInbox() throws {
        let json = #"""
        [
          {"id":"A","author":"claude-code:@app","agentSessionId":"live-1","body":{"kind":"tombstone","status":"open","requiresNotary":true,"draft":{"claim":"LOG_BUDGET 30 is dead"},"signal":{"source":"agent-draft","detail":"bumped in a1b2c3"}}},
          {"id":"B","author":"detector:supersession","body":{"kind":"tombstone","status":"open","draft":{"claim":"x"},"signal":{"source":"supersession-detector"}}},
          {"id":"C","author":"claude-code:@app","body":{"kind":"tombstone","status":"signed","requiresNotary":true,"draft":{"claim":"y"},"signal":{"source":"agent-draft"}}}
        ]
        """#
        let base = URL(string: "http://127.0.0.1:8787")!
        let drafts = try NotaryClient.parseInbox(Data(json.utf8), restBase: base)
        #expect(drafts.map(\.id) == ["A"])
        #expect(drafts[0].draftedBy == "claude-code:@app")
        #expect(drafts[0].sessionIds == ["live-1"])
        #expect(drafts[0].content.contains("LOG_BUDGET 30 is dead"))
        #expect(drafts[0].content.contains("Why: bumped in a1b2c3"))
        #expect(drafts[0].notarizeURL?.absoluteString == "http://127.0.0.1:8787/proposals/A/notarize")
    }
}

@MainActor
@Suite("Notary inbox")
struct NotaryInboxTests {
    func makeModel() -> (MessengerModel, MockAgentTransport) {
        let transport = MockAgentTransport()
        let model = MessengerModel(store: MessengerStore(url: nil), transport: transport, scanner: nil)
        model.rebuildAgents(discovered: [
            DiscoveredSession(sessionId: "live-1", cwd: "/r/app", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil,
                              live: LiveSessionRecord(pid: 1, sessionId: "live-1", name: "app-live", status: "busy")),
        ])
        return (model, transport)
    }

    @Test("a draft is queued for the user, noted in the agent's chat, and never relayed to the agent")
    func queued() async throws {
        let (model, transport) = makeModel()
        model.handleChannelEvent(proposalEvent())
        model.handleChannelEvent(proposalEvent())  // a retried push
        for _ in 0..<20 { await Task.yield() }

        #expect(model.pendingProposals.map(\.id) == ["01PROP"])
        #expect(model.pendingProposals.first?.state == .awaiting)
        #expect(model.objections.isEmpty)
        let chat = try #require(model.directConversation(with: "live-1"))
        #expect(chat.messages.contains { $0.author == .stenographer && $0.text.contains("Approve or decline") })
        #expect(transport.sent.isEmpty, "the drafting agent must not receive its own draft as a message")
    }

    @Test("approving needs a signer identity")
    func needsSigner() async {
        let (model, _) = makeModel()
        model.settings.signerIdentity = ""
        model.handleChannelEvent(proposalEvent())
        await model.decide(proposalId: "01PROP", .approve(notary: model.settings.signerIdentity))
        guard case .failed(let message) = model.pendingProposals.first?.state else {
            Issue.record("expected a failure, got \(String(describing: model.pendingProposals.first?.state))")
            return
        }
        #expect(message.contains("sign as"))
    }

    @Test("settings from before the REST port existed still load")
    func restPortDefault() throws {
        let data = Data(#"{"wikiPaths":[],"switchboardModel":"haiku","stenographerModel":"sonnet","stenographerWatching":true}"#.utf8)
        let settings = try JSONDecoder().decode(MessengerSettings.self, from: data)
        #expect(settings.stenographerRestPort == MessengerSettings.defaultStenographerRestPort)
    }
}
