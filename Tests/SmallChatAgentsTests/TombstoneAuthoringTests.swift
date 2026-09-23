import Foundation
import Testing
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

    @Test("a complete draft signs into a trimmed, active TB")
    func signs() throws {
        #expect(good.problems().isEmpty)
        let tb = try good.sign(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(tb.claim == "LOG_BUDGET 30 is dead; the budget is 100.")
        #expect(tb.signedBy == "johnny" && tb.author == "johnny")
        #expect(tb.status == .active)
        #expect(tb.evidence == [TruthEvidence(kind: .commit, ref: "a1b2c3", detail: nil)])
        #expect(tb.id.count == 26)
        #expect(tb.ts.hasPrefix("2026-09-21T"))
    }

    @Test("every blocking problem is reported")
    func problems() {
        let bad = TombstoneDraft(claim: " ", evidence: [TruthEvidence(kind: .file, ref: "")],
                                 literals: [TruthTombstonedLiteral(dead: "30")], signer: "assistant")
        let problems = bad.problems()
        #expect(problems.count == 4)
        #expect(problems.contains { $0.contains("Literal 1") })
        #expect(problems.contains { $0.contains("accountable") })
        #expect(throws: TruthError.self) { try bad.sign() }
        #expect(TombstoneDraft(claim: "c", signer: "j").problems() == ["Add at least one piece of evidence."])
    }

    @Test("appending keeps one entry per line, even after a file with no trailing newline")
    func append() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)/team.jsonl").path
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tb = try good.sign()
        try TruthWiki.append([.tb(tb)], toFileAt: path)  // creates dirs + file
        try FileHandle(forWritingAtPath: path).map { h in h.seekToEndOfFile(); h.write(Data(#"{"id":"UVX","type":"UV","status":"open"}"#.utf8)); h.closeFile() }
        try TruthWiki.append([.tb(tb)], toFileAt: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(text.split(separator: "\n").count == 3)
        let parsed = TruthWiki.parse(text)
        #expect(parsed.errors.isEmpty)
        guard case .tb(let back)? = parsed.entries.first(where: { $0.id == tb.id }) else { Issue.record("missing TB"); return }
        #expect(back.literals == tb.literals)
    }
}

@MainActor
@Suite("Authoring in the model")
struct TombstoneModelTests {
    @Test("authored literals take effect immediately and the wiki path is tracked")
    func endToEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikidir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = MessengerModel(store: MessengerStore(url: nil), transport: MockAgentTransport(), scanner: nil)
        #expect(model.tombstoneTarget == nil)
        #expect(throws: TruthError.self) { try model.assertTombstone(TombstoneDraftTests().good) }

        model.settings.wikiPaths = [dir.path]
        #expect(model.tombstoneTarget == dir.appendingPathComponent("smallchat-tombstones.jsonl").path)
        let tb = try model.assertTombstone(TombstoneDraftTests().good)
        #expect(model.ledger.tombstones.map(\.id) == [tb.id])
        #expect(model.settings.signerIdentity == "johnny")
        #expect(model.settings.wikiPaths == [dir.path], "directory already covers the file")

        model.rebuildAgents(discovered: [DiscoveredSession(sessionId: "a1", cwd: "/r/x", gitBranch: nil, title: nil, lastActivity: Date(), transcriptPath: nil, live: nil)])
        let chat = try #require(model.openDirect(agentId: "a1"))
        model.send("let's set logBudget = 30 for now", in: chat)
        #expect(model.conversation(chat)?.messages.contains { $0.author == .stenographer && $0.citedEntryId == tb.id } == true)
    }
}
