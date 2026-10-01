import Foundation
import Testing
import SmallChatCore
@testable import SmallChatAgents
@testable import SmallChatTruth

@Suite("Tombstone drafts")
struct TombstoneDraftTests {
    let good = TombstoneDraft(
        claim: "  LOG_BUDGET 30 is dead; the budget is 100.  ",
        evidence: [TruthEvidence(kind: .commit, ref: " a1b2c3 ", detail: " ")],
        literals: [TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100")],
        signer: "johnny"
    )

    @Test("a complete draft becomes a trimmed PROPOSAL envelope, a valid truth format v2 line")
    func proposal() throws {
        #expect(good.problems().isEmpty)
        let envelope = try good.proposal(author: MessengerModel.proposalAuthor, id: "01J9MSGRTB0000000000000001", now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(envelope.kind == "tb")
        #expect(envelope.author == "agent:smallchat-messenger")
        #expect(envelope.signal.source == "agent")
        #expect(envelope.ts == "2026-09-21T14:13:20.000Z")
        guard case .tb(let claim, let evidence, let literals) = envelope.draft else {
            Issue.record("not a TB draft")
            return
        }
        #expect(claim == "LOG_BUDGET 30 is dead; the budget is 100.")
        #expect(evidence == [TruthEvidence(kind: .commit, ref: "a1b2c3", detail: nil)])
        #expect(literals == [TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100")])

        let line = try envelope.line()
        let decoded = try TruthFormat.decode(line)
        #expect(decoded.type == .proposal && decoded.seq == 1 && decoded.prevHash == nil)
        #expect(line.hasPrefix(#"{"schemaVersion":2,"seq":1,"id":"01J9MSGRTB0000000000000001","type":"PROPOSAL""#))
    }

    @Test("every blocking problem is reported")
    func problems() {
        let bad = TombstoneDraft(claim: " ", evidence: [TruthEvidence(kind: .file, ref: "")],
                                 literals: [TruthTombstonedLiteral(dead: "30")], signer: "assistant")
        let problems = bad.problems()
        #expect(problems.count == 4)
        #expect(problems.contains { $0.contains("Literal 1") })
        #expect(problems.contains { $0.contains("accountable") })
        #expect(throws: TruthError.self) { try bad.proposal(author: MessengerModel.proposalAuthor) }
        #expect(TombstoneDraft(claim: "c", signer: "j").problems() == ["Add at least one piece of evidence."])
        // Reserved identities can't sign either
        #expect(TombstoneDraft(claim: "c", evidence: [TruthEvidence(kind: .commit, ref: "x")], signer: "migration").problems().count == 1)
    }

    @Test("SC-SW-33: a literal without a subject needs an ASCII letter and 4 UTF-16 units, as stenographer counts")
    func literalRule() {
        let draft = { (dead: String) in
            TombstoneDraft(claim: "c", evidence: [TruthEvidence(kind: .commit, ref: "x")], literals: [TruthTombstonedLiteral(dead: dead)], signer: "johnny")
        }
        #expect(!draft("日本語版").problems().isEmpty)
        #expect(!draft("ÅÅÅÅ").problems().isEmpty)
        #expect(draft("e\u{301}e\u{301}").problems().isEmpty)
    }

    @Test("the drafter can't be the notary: stenographer would refuse it as contempt of corpus")
    func drafterIsNotNotary() {
        let draft = TombstoneDraft(claim: "c", evidence: [TruthEvidence(kind: .commit, ref: "x")], signer: "Agent:SmallChat-Messenger")
        #expect(throws: TruthError.self) { try draft.proposal(author: MessengerModel.proposalAuthor) }
    }
}

@MainActor
@Suite("Authoring in the model")
struct TombstoneModelTests {
    private func makeModel() -> MessengerModel {
        MessengerModel(store: MessengerStore(url: nil), transport: MockAgentTransport(), scanner: nil)
    }

    private func fake(for model: MessengerModel) async throws -> FakeStenographer {
        let fake = try await FakeStenographer.start(notarySecret: model.notarySecret, restToken: model.restToken)
        model.settings.stenographerRestPort = fake.port
        return fake
    }

    @Test("SC-SW-14 / XSUITE-06: signing a tombstone never writes to stenographer's export file")
    func oneWriterPerFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let export = dir.appendingPathComponent("wiki.jsonl")
        let exported = #"{"id":"01J9V1UV000000000000000000","type":"UV","ts":"2026-03-01T09:03:00.000Z","author":"sam","assertion":"The cron box has a stale hosts file.","basis":"deploys skip it","verifyBy":{"kind":"ask","value":"ops"},"contests":null,"status":"open"}"# + "\n"
        try Data(exported.utf8).write(to: export)

        let model = makeModel()
        model.settings.wikiPaths = [export.path]
        let stenographer = try await fake(for: model)
        defer { Task { try? await stenographer.shutdown() } }
        _ = try await model.assertTombstone(TombstoneDraftTests().good)

        #expect(try String(contentsOf: export, encoding: .utf8) == exported)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["wiki.jsonl"])
        // It went to stenographer instead: one PROPOSAL envelope, then the notarization
        #expect(stenographer.requests.map(\.path) == ["/proposals", "/proposals/01PROPOSAL0000000000000001/notarize"])
    }

    @Test("signing with stenographer unreachable fails, and still writes nothing")
    func unreachable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = makeModel()
        model.settings.wikiPaths = [dir.path]
        model.settings.stenographerRestPort = 1  // nothing listens there
        await #expect(throws: (any Error).self) { try await model.assertTombstone(TombstoneDraftTests().good) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(model.authoredTombstones.isEmpty)
    }

    @Test("the envelope goes to POST /proposals with both secrets, and the signer notarizes it")
    func requests() async throws {
        let model = makeModel()
        let stenographer = try await fake(for: model)
        defer { Task { try? await stenographer.shutdown() } }
        let tb = try await model.assertTombstone(TombstoneDraftTests().good)

        let (submit, notarize) = (stenographer.requests[0], stenographer.requests[1])
        for request in [submit, notarize] {
            #expect(request.headers["x-notary-secret"] == model.notarySecret)
            #expect(request.headers["authorization"] == "Bearer \(model.restToken)")
            #expect(request.headers["x-notary-secret"] != model.channelSecret)
        }
        let line = try TruthFormat.decode(String(decoding: submit.body, as: UTF8.self))
        #expect(line.type == .proposal)
        #expect(line.object["author"] == .string("agent:smallchat-messenger"))
        #expect(line.object["kind"] == .string("tb"))
        #expect(try parseJSON(notarize.body) == .dict(["notary": .string("johnny")]))

        #expect(tb.id == "01MINTED000000000000000001")
        #expect(tb.signedBy == "johnny" && tb.author == "johnny" && tb.status == .active)
        #expect(tb.literals == [TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100")])
    }

    @Test("a signing that failed at notarization is retried with the same envelope, which stenographer files once")
    func retry() async throws {
        let model = makeModel()
        let stenographer = try await fake(for: model)
        defer { Task { try? await stenographer.shutdown() } }

        stenographer.failNotarize = (500, "the ledger is busy")
        await #expect(throws: NotaryError.rejected(status: 500, message: "the ledger is busy")) {
            try await model.assertTombstone(TombstoneDraftTests().good)
        }
        stenographer.failNotarize = nil
        let tb = try await model.assertTombstone(TombstoneDraftTests().good)
        #expect(tb.id == "01MINTED000000000000000001")

        let submissions = stenographer.requests.filter { $0.path == "/proposals" }
        #expect(submissions.count == 2)
        #expect(submissions[0].body == submissions[1].body, "the same envelope, so the same proposal")
    }

    @Test("authored literals take effect immediately, until the wiki export speaks for the TB")
    func endToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikidir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = makeModel()
        model.settings.wikiPaths = [dir.path]
        let stenographer = try await fake(for: model)
        defer { Task { try? await stenographer.shutdown() } }
        let tb = try await model.assertTombstone(TombstoneDraftTests().good)
        #expect(model.ledger.tombstones.map(\.id) == [tb.id])
        #expect(model.settings.signerIdentity == "johnny")
        #expect(model.settings.wikiPaths == [dir.path])

        model.rebuildAgents(discovered: [DiscoveredSession(sessionId: "a1", cwd: "/r/x", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil)])
        let chat = try #require(model.openDirect(agentId: "a1"))
        model.send("let's set logBudget = 30 for now", in: chat)
        #expect(model.conversation(chat)?.messages.contains { $0.author == .stenographer && $0.citedEntryId == tb.id } == true)

        // Stenographer's export now carries the TB, struck by a ruling: the export speaks for it
        let export = try TruthFormat.chain([
            #"{"id":"\#(tb.id)","type":"TB","ts":"2026-10-01T12:00:00.000Z","author":"johnny","claim":"LOG_BUDGET 30 is dead; the budget is 100.","evidence":[{"kind":"commit","ref":"a1b2c3"}],"signedBy":"johnny","literals":[{"dead":"30","subject":"LOG_BUDGET","current":"100"}],"status":"active"}"#,
            #"{"id":"01RULING0000000000000000001","type":"RULING","ts":"2026-10-01T12:05:00.000Z","author":"kim","kind":"strike","opinion":"the commit was reverted","target":"\#(tb.id)"}"#,
            #"{"id":"01RULING0000000000000000001:\#(tb.id)","type":"TRANSITION","ts":"2026-10-01T12:05:00.000Z","author":"kim","target":"\#(tb.id)","status":"struck","cause":{"kind":"strike","ref":"01RULING0000000000000000001"}}"#,
        ])
        try Data((export.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("johnny.jsonl"))
        model.reloadLedger()
        #expect(model.authoredTombstones.isEmpty)
        #expect(model.ledger.errors.isEmpty)
        let before = model.conversation(chat)?.messages.count ?? 0
        model.send("still logBudget = 30 here", in: chat)
        #expect(model.conversation(chat)?.messages.dropFirst(before).contains { $0.author == .stenographer } == false)
    }
}
