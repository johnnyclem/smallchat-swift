import Foundation
import Testing
@testable import SmallChatCompaction
@testable import SmallChatTruth

@Suite("Truth ledger interop")
struct TruthTests {

    // MARK: - Fixtures (shaped like stenographer's export_wiki_entries output)

    // Version 1 lines (stenographer 0.x); `parseFixtures` chains them into a
    // truth format v2 stream.
    private let tbLine = """
    {"id":"01JAAAAAAAAAAAAAAAAAAAAAA1","type":"TB","ts":"2026-09-18T10:00:00.000Z","author":"johnny","claim":"The REST fallback path is dead; all traffic goes through MCP.","evidence":[{"kind":"commit","ref":"abc1234","detail":"removed rest-fallback.ts"}],"signedBy":"johnny","status":"active","x-steno":{"origin":"local","provenance":{"kind":"commitSha","ref":"abc1234"},"agentSessionId":null,"links":[]}}
    """

    private let uvLine = """
    {"id":"01JAAAAAAAAAAAAAAAAAAAAAA2","type":"UV","ts":"2026-09-18T11:00:00.000Z","author":"sam","assertion":"The embedder cache is safe to share across worker threads.","basis":"No crash observed in three weeks of soak testing.","verifyBy":{"kind":"command","value":"npm run test -- embedding"},"contests":null,"status":"open","x-steno":{"origin":"wiki","provenance":{"kind":"manual"},"agentSessionId":null,"links":[]}}
    """

    /// The two fixture entries as a v2 stream: stenographer 1.0 writes them like this.
    private var v2Lines: [String] {
        chainTruthLines([tbLine, uvLine])
    }

    private func parseFixtures() -> [TruthLedgerEntry] {
        let result = TruthWiki.parse(lines: v2Lines)
        #expect(result.errors.isEmpty)
        return result.entries
    }

    private func asJSONObject(_ line: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    // MARK: - Round trip

    @Test("JSONL round trip writes every line back byte for byte, x-steno included")
    func roundTrip() throws {
        let entries = parseFixtures()
        #expect(entries.count == 2)
        #expect(TruthWiki.serialize(entries) == v2Lines)

        // An entry built in code is written in the v1 shape, with every field
        let rebuilt = entries.map { entry -> TruthLedgerEntry in
            switch entry {
            case .tb(var tb): tb.source = nil; return .tb(tb)
            case .uv(var uv): uv.source = nil; return .uv(uv)
            }
        }
        let reserialized = TruthWiki.serialize(rebuilt)
        #expect(try asJSONObject(reserialized[0]) == asJSONObject(tbLine))
        #expect(try asJSONObject(reserialized[1]) == asJSONObject(uvLine))
    }

    @Test("Version 1: later lines for the same id supersede earlier ones")
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

    @Test("Version 1: per-line errors never poison the rest of the file; a v2 stream is refused whole")
    func tolerantParsing() {
        let ruling = #"{"id":"x","type":"RULING","status":"active"}"#
        let result = TruthWiki.parse(lines: ["not json", "", tbLine, ruling, uvLine])
        #expect(result.entries.count == 2)
        #expect(result.errors.count == 2)
        #expect(result.errors.map(\.line) == [1, 4], "blank lines count")

        // A refused line could be the TRANSITION that struck a TB: nothing in the stream is truth
        let stream = TruthWiki.parse(lines: [v2Lines[0], "not json", v2Lines[1]])
        #expect(stream.refused && stream.entries.isEmpty)
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
        #expect(first.signal.source == "compaction-candidate")

        let lines = TruthProposals.serialize([first])
        #expect(lines.count == 1)
        // A suite PROPOSAL envelope: a truth format v2 line, first of its stream
        let decoded = try TruthFormat.decode(lines[0])
        #expect(decoded.type == .proposal && decoded.seq == 1)
        #expect(decoded.object["kind"] == .string("uv"))
        #expect(TruthProposals.head(of: lines) == TruthStreamHead(seq: 1, hash: decoded.hash!))
        // Appending continues the stream
        let next = TruthProposals.serialize([try InvariantProposal(author: "johnny", draft: draft, targetRef: "entity:sess-1:cache")], after: TruthProposals.head(of: lines))
        #expect(try TruthFormat.decode(next[0]).seq == 2)
        #expect(TruthFormat.checkChain([decoded, try TruthFormat.decode(next[0])]).isEmpty)

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

@Suite("Tombstoned literal validation")
struct LiteralValidationTests {
    @Test("matches stenographer's write-time rule")
    func rule() {
        #expect(TruthTombstonedLiteral(dead: "30", subject: "LOG_BUDGET", current: "100").validationError() == nil)
        #expect(TruthTombstonedLiteral(dead: "legacyRateLimiter").validationError() == nil)
        #expect(TruthTombstonedLiteral(dead: "30").validationError() != nil, "bare value needs a subject")
        #expect(TruthTombstonedLiteral(dead: "abc").validationError() != nil, "too short to be distinctive")
        #expect(TruthTombstonedLiteral(dead: "1234").validationError() != nil, "no letter")
        #expect(TruthTombstonedLiteral(dead: "  ").validationError() != nil)
        #expect(TruthTombstonedLiteral(dead: "x", subject: " ").validationError() != nil)
    }

    @Test("a TB line with an invalid literal is rejected; the rest of the file still loads")
    func rejectsLine() {
        // Version 1 lines: a file without a chain keeps its per-line tolerance
        let bad = #"{"id":"TB1","type":"TB","ts":"2026-09-18T10:00:00.000Z","author":"alice","claim":"c","evidence":[{"kind":"commit","ref":"x"}],"signedBy":"alice","status":"active","literals":[{"dead":"30"}]}"#
        let good = #"{"id":"TB2","type":"TB","ts":"2026-09-18T10:00:00.000Z","author":"alice","claim":"c","evidence":[{"kind":"commit","ref":"x"}],"signedBy":"alice","status":"active","literals":[{"dead":"30","subject":"LOG_BUDGET"}]}"#
        let result = TruthWiki.parse(lines: [bad, good])
        #expect(result.entries.map(\.id) == ["TB2"])
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.description.contains("TB1") == true)
    }
}
