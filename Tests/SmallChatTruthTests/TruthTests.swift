import Foundation
import Testing
@testable import SmallChatCompaction
@testable import SmallChatTruth

@Suite("Truth ledger interop")
struct TruthTests {

    // MARK: - Fixtures (shaped like stenographer's export_wiki_entries output)

    private let tbLine = """
    {"id":"01JAAAAAAAAAAAAAAAAAAAAAA1","type":"TB","ts":"2026-09-18T10:00:00.000Z","author":"johnny","claim":"The REST fallback path is dead; all traffic goes through MCP.","evidence":[{"kind":"commit","ref":"abc1234","detail":"removed rest-fallback.ts"}],"signedBy":"johnny","status":"active","x-steno":{"origin":"local","provenance":{"kind":"commitSha","ref":"abc1234"},"agentSessionId":null,"links":[]}}
    """

    private let uvLine = """
    {"id":"01JAAAAAAAAAAAAAAAAAAAAAA2","type":"UV","ts":"2026-09-18T11:00:00.000Z","author":"sam","assertion":"The embedder cache is safe to share across worker threads.","basis":"No crash observed in three weeks of soak testing.","verifyBy":{"kind":"command","value":"npm run test -- embedding"},"contests":null,"status":"open","x-steno":{"origin":"wiki","provenance":{"kind":"manual"},"agentSessionId":null,"links":[]}}
    """

    private func parseFixtures() -> [TruthLedgerEntry] {
        let result = TruthWiki.parse(lines: [tbLine, uvLine])
        #expect(result.errors.isEmpty)
        return result.entries
    }

    private func asJSONObject(_ line: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    // MARK: - Round trip

    @Test("JSONL round trip preserves every field including x-steno")
    func roundTrip() throws {
        let entries = parseFixtures()
        #expect(entries.count == 2)

        let reserialized = TruthWiki.serialize(entries)
        #expect(reserialized.count == 2)
        let tbRoundTrip = try asJSONObject(reserialized[0])
        let uvRoundTrip = try asJSONObject(reserialized[1])
        let tbOriginal = try asJSONObject(tbLine)
        let uvOriginal = try asJSONObject(uvLine)
        #expect(tbRoundTrip == tbOriginal)
        #expect(uvRoundTrip == uvOriginal)
    }

    @Test("Later lines for the same id supersede earlier ones")
    func appendOnlySupersession() throws {
        let overridden = tbLine.replacingOccurrences(of: "\"status\":\"active\"", with: "\"status\":\"overridden\"")
        let result = TruthWiki.parse(lines: [tbLine, uvLine, overridden])
        #expect(result.entries.count == 2)
        guard case .tb(let tb)? = result.entries.first(where: { $0.id == "01JAAAAAAAAAAAAAAAAAAAAAA1" }) else {
            Issue.record("TB entry missing")
            return
        }
        #expect(tb.status == .overridden)
    }

    @Test("Per-line errors never poison the rest of the file")
    func tolerantParsing() {
        let ruling = #"{"id":"x","type":"RULING","status":"active"}"#
        let result = TruthWiki.parse(lines: ["not json", "", tbLine, ruling, uvLine])
        #expect(result.entries.count == 2)
        #expect(result.errors.count == 2)
    }

    // MARK: - Consumption rules (§7)

    @Test("Lifecycle states classify per §7")
    func classification() throws {
        let entries = parseFixtures()
        guard case .tb(var tb) = entries[0], case .uv(var uv) = entries[1] else {
            Issue.record("fixture shape unexpected")
            return
        }

        #expect(TruthWiki.classify(.tb(tb)) == .groundTruth)
        tb.status = .contested
        #expect(TruthWiki.classify(.tb(tb)) == .contested)
        tb.status = .overridden
        #expect(TruthWiki.classify(.tb(tb)) == .history)

        #expect(TruthWiki.classify(.uv(uv)) == .flag)
        uv.status = .refuted
        #expect(TruthWiki.classify(.uv(uv)) == .history)
        uv.status = .verified
        #expect(TruthWiki.classify(.uv(uv)) == .history)
    }

    private func contestedFixture() -> (tb: TruthTbEntry, contesting: TruthUvEntry, standalone: TruthUvEntry) {
        let tb = TruthTbEntry(
            id: "TB2", ts: "2026-09-18T10:00:00.000Z", author: "johnny",
            claim: "All embeddings are 384-dimensional.",
            evidence: [TruthEvidence(kind: .commit, ref: "abc1234")],
            signedBy: "johnny", status: .contested
        )
        let contesting = TruthUvEntry(
            id: "UV1", ts: "2026-09-18T11:00:00.000Z", author: "sam",
            assertion: "The ONNX path still emits 768-dim vectors on fallback.",
            basis: "Saw it once in a debug log.",
            verifyBy: TruthVerifyBy(kind: .command, value: "swift test --filter Embedding"),
            contests: "TB2", status: .open
        )
        let standalone = TruthUvEntry(
            id: "UV2", ts: "2026-09-18T12:00:00.000Z", author: "sam",
            assertion: "The embedder cache is safe to share across worker threads.",
            basis: "No crash in three weeks of soak testing.",
            verifyBy: TruthVerifyBy(kind: .observe, value: "crash reports"),
            contests: nil, status: .open
        )
        return (tb, contesting, standalone)
    }

    @Test("Contested TBs pair with their live contesting UVs; history is excluded")
    func selection() {
        let (tb, contesting, standalone) = contestedFixture()
        var refuted = standalone
        refuted.status = .refuted
        let refutedEntry = TruthUvEntry(
            id: "UV3", ts: refuted.ts, author: refuted.author, assertion: refuted.assertion,
            basis: refuted.basis, verifyBy: refuted.verifyBy, contests: nil, status: .refuted
        )

        let selection = TruthWiki.selectCurrentTruth([
            .tb(tb), .uv(contesting), .uv(standalone), .uv(refutedEntry),
        ])

        #expect(selection.groundTruth.isEmpty)
        #expect(selection.contested.count == 1)
        #expect(selection.contested[0].tombstone.id == "TB2")
        #expect(selection.contested[0].contestedBy.map(\.id) == ["UV1"])
        #expect(selection.unverified.map(\.id).sorted() == ["UV1", "UV2"])
        #expect(selection.history.map(\.id) == ["UV3"])
    }

    // MARK: - Rendering & compaction bridge

    @Test("Rendering marks every confidence type; UVs never read as proven")
    func rendering() {
        let (tb, contesting, standalone) = contestedFixture()
        let selection = TruthWiki.selectCurrentTruth([.tb(tb), .uv(contesting), .uv(standalone)])
        let text = TruthCompaction.renderSection(selection)

        #expect(text.contains("[TB ⚠ CONTESTED] All embeddings are 384-dimensional."))
        #expect(text.contains("disputed by [UV — UNVERIFIED] The ONNX path still emits 768-dim vectors"))
        #expect(text.contains("[UV — UNVERIFIED] The embedder cache is safe to share"))
        for line in text.split(separator: "\n") where line.contains("ONNX") || line.contains("embedder cache") {
            #expect(line.contains("UNVERIFIED"))
        }
    }

    @Test("Truth items survive verification; dropping one fails the invariant")
    func verifierIntegration() {
        let (tb, contesting, standalone) = contestedFixture()
        let selection = TruthWiki.selectCurrentTruth([.tb(tb), .uv(contesting), .uv(standalone)])
        let truthItems = TruthCompaction.compactionItems(selection)
        #expect(truthItems.map(\.id).sorted() == ["truth:TB2", "truth:UV2"])

        let corpus = [CompactionItem(id: "1", text: "alpha bravo charlie")] + truthItems
        let verifier = CompactionVerifier(invariants: [TruthInvariants.preserved(selection)])

        // Compaction that keeps the truth items passes the invariant.
        let good = verifier.verify(before: corpus, after: truthItems)
        #expect(good.diffInvariants.passed)

        // Compaction that drops a truth item fails.
        let dropped = verifier.verify(before: corpus, after: [truthItems[0]])
        #expect(!dropped.diffInvariants.passed)

        // Compaction that strips the UNVERIFIED marker fails — silent
        // promotion of a UV to proven is the one thing this seam forbids.
        let promoted = truthItems.map { item in
            CompactionItem(id: item.id, text: item.text.replacingOccurrences(of: "[UV — UNVERIFIED] ", with: ""))
        }
        let stripped = verifier.verify(before: corpus, after: promoted)
        #expect(!stripped.diffInvariants.passed)
        #expect(stripped.diffInvariants.violations.first?.contains("UNVERIFIED") == true)
    }

    @Test("L4 records keep the confidence axis riding along")
    func invariantRecords() {
        let (tb, contesting, standalone) = contestedFixture()
        let selection = TruthWiki.selectCurrentTruth([.tb(tb), .uv(contesting), .uv(standalone)])
        let records = TruthCompaction.invariantRecords(selection)
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })

        #expect(byKey["truth:TB2"]?.contested == true)
        #expect(byKey["truth:TB2"]?.confidence == .tb)
        #expect(byKey["truth:TB2"]?.value.contains("disputed: The ONNX path") == true)
        #expect(byKey["truth:UV2"]?.confidence == .uv)
        #expect(byKey["truth:UV2"]?.value.contains("[UV — UNVERIFIED]") == true)
        // Contesting UVs ride their TB — no standalone record.
        #expect(byKey["truth:UV1"] == nil)
    }

    // MARK: - Proposals & authorship

    @Test("Proposals serialize as JSONL and dedupe by targetRef")
    func proposals() throws {
        let draft = InvariantProposal.Draft(
            assertion: "database is postgres.",
            basis: "Compacted from session sess-1.",
            verifyBy: TruthVerifyBy(kind: .inspect, value: "message:m1")
        )
        let first = try InvariantProposal(author: "johnny", draft: draft, targetRef: "entity:sess-1:database")
        #expect(first.type == "PROPOSAL")
        #expect(first.kind == "uv")
        #expect(first.id.count == 26)
        #expect(first.signal.source == "shorthand-compaction")

        let lines = TruthProposals.serialize([first])
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"type\":\"PROPOSAL\""))

        let second = try InvariantProposal(author: "johnny", draft: draft, targetRef: "entity:sess-1:database")
        let fresh = TruthProposals.deduplicate([second], againstExisting: lines)
        #expect(fresh.isEmpty)

        let other = try InvariantProposal(author: "johnny", draft: draft, targetRef: "entity:sess-1:orm")
        #expect(TruthProposals.deduplicate([other], againstExisting: lines).count == 1)
    }

    @Test("Anonymous identities are rejected — there is no anonymous write path")
    func anonymousRejection() {
        let draft = InvariantProposal.Draft(
            assertion: "x", basis: "y",
            verifyBy: TruthVerifyBy(kind: .ask, value: "johnny")
        )
        for bad in ["system", "assistant", " AGENT ", "", "anonymous"] {
            #expect(isAnonymousIdentity(bad))
            #expect(throws: TruthError.self) {
                _ = try InvariantProposal(author: bad, draft: draft)
            }
        }
        #expect(!isAnonymousIdentity("johnny"))
    }

    @Test("ULID is 26 characters and time-prefixed sortable")
    func ulidShape() {
        let earlier = ulid(now: Date(timeIntervalSince1970: 1_726_000_000))
        let later = ulid(now: Date(timeIntervalSince1970: 1_726_000_100))
        #expect(earlier.count == 26)
        #expect(later.count == 26)
        #expect(String(earlier.prefix(10)) < String(later.prefix(10)))
    }
}
