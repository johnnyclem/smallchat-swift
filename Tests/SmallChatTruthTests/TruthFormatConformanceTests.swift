import Foundation
import Testing
import SmallChatCore
@testable import SmallChatTruth

// Truth format v2 conformance — stenographer's golden fixtures.
//
// Tests/Fixtures/truth-format/ is a copy of stenographer's spec/truth-format
// (README, JSON Schema, fixtures), made by Scripts/sync-truth-fixtures.sh,
// which records the source commit and every file's sha256 in SOURCE. Each
// fixture's *.expected.json states the outcome a conforming reader must
// reach; these tests check that SmallChatTruth reaches it.
//
// Several expected files also describe stenographer's own import (whether a
// line is inserted into its ledger, filed as a reconciliation proposal, or
// held). A reader does not import: the parts that apply to it are that
// `inserted` lines are read with that status, that `proposal` lines never
// become current truth (for the reasons a reader applies: unsigned,
// unverifiable, an unknown status), and that `held` lines change no status.

enum TruthFixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/truth-format")

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    static func text(_ path: String) throws -> String {
        try String(decoding: data(path), as: UTF8.self)
    }

    /// The file's non-empty lines.
    static func lines(_ path: String) throws -> [String] {
        try text(path).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func json(_ path: String) throws -> AnyCodableValue {
        try parseJSON(data(path))
    }

    static func object(_ line: String) -> [String: AnyCodableValue] {
        guard case .dict(let object)? = try? parseJSON(line) else { return [:] }
        return object
    }

    static func string(_ value: AnyCodableValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    static func int(_ value: AnyCodableValue?) -> Int? {
        if case .int(let i)? = value { return i }
        return nil
    }

    static func array(_ value: AnyCodableValue) -> [AnyCodableValue] {
        if case .array(let items) = value { return items }
        return []
    }

    static let schema: JSONSchemaValidator = try! JSONSchemaValidator(schema: try! json("wiki-line.v2.schema.json"))

    static func schemaValid(_ line: String) -> Bool {
        guard let value = try? parseJSON(line) else { return false }
        return schema.isValid(value)
    }

    static func signers() throws -> TruthSignerRegistry {
        try TruthSignerRegistry(json: data("signers.json"))
    }

    /// `{id: {type, status, current}}` from an expected file.
    static func table(_ value: AnyCodableValue) -> [String: TruthStatusRow] {
        guard case .dict(let rows) = value else { return [:] }
        var table: [String: TruthStatusRow] = [:]
        for (id, row) in rows {
            guard case .dict(let r) = row, case .bool(let current)? = r["current"] else { continue }
            table[id] = TruthStatusRow(type: string(r["type"]) ?? "", status: string(r["status"]), current: current)
        }
        return table
    }
}

@Suite("Truth format v2 conformance (stenographer fixtures)")
struct TruthFormatConformanceTests {
    typealias F = TruthFixtures

    // MARK: Provenance and the spec document

    @Test("SOURCE names the stenographer commit, and every file matches the hash it recorded")
    func provenance() throws {
        let source = try F.text("SOURCE")
        let commit = source.components(separatedBy: "\n").first { $0.hasPrefix("commit: ") }
        #expect(commit.map { $0.dropFirst(8).count == 40 && $0.dropFirst(8).allSatisfy(\.isHexDigit) } == true)

        var listed: [String: String] = [:]
        for line in source.components(separatedBy: "\n") where line.hasPrefix("  ") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2 { listed[String(parts[1])] = String(parts[0]) }
        }
        var present: [String] = []
        let enumerator = FileManager.default.enumerator(at: F.root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(F.root.standardizedFileURL.path.count + 1))
            if relative != "SOURCE" { present.append(relative) }
        }
        #expect(present.sorted() == listed.keys.sorted(), "re-run Scripts/sync-truth-fixtures.sh")
        for file in present {
            #expect(sha256Hex(Array(try F.data(file))) == listed[file], "\(file) was edited by hand; re-run Scripts/sync-truth-fixtures.sh")
        }
    }

    @Test("the README's worked example: its canonical form and hash, byte for byte")
    func workedExample() throws {
        let readme = try F.text("README.md")
        let marker = try #require(readme.range(of: "<!-- worked-example -->\n```json\n"))
        let line = String(readme[marker.upperBound...].prefix { $0 != "\n" })
        #expect(try F.lines("valid/ledger.jsonl").contains(line))

        var object = F.object(line)
        let hash = try #require(F.string(object["hash"]))
        object.removeValue(forKey: "hash")
        let jcs = try canonicalJSON(.dict(object))
        #expect(readme.contains("```\n" + jcs + "\n```"))
        #expect(sha256Hex(Array(jcs.utf8)) == hash)
        #expect(try TruthFormat.hash(line: line) == hash)
        #expect(hash == "8c366a06018886baa0ca9456661e4895a272faebf88e188f409efc580b5465fb")
    }

    // MARK: valid/

    @Test("valid/ledger.jsonl: every line passes the schema and the codec, its hash recomputes, and the lines chain")
    func ledgerLines() throws {
        let lines = try F.lines("valid/ledger.jsonl")
        var decoded: [DecodedTruthLine?] = []
        for (i, line) in lines.enumerated() {
            #expect(F.schemaValid(line), "line \(i + 1)")
            let d = try TruthFormat.decode(line)
            #expect(d.version == 2 && d.seq == i + 1 && d.hash == F.string(F.object(line)["hash"]))
            #expect(try TruthFormat.hash(line: line) == d.hash)
            decoded.append(d)
        }
        #expect(TruthFormat.checkChain(decoded).isEmpty)
    }

    @Test("valid/ledger.jsonl folds to ledger.expected.json, with and without the signer registry")
    func ledgerFold() throws {
        let want = F.table(try F.json("valid/ledger.expected.json"))
        let plain = TruthWiki.parse(try F.text("valid/ledger.jsonl"))
        #expect(plain.errors.isEmpty && !plain.refused)
        #expect(TruthWiki.statusTable(plain.entries) == want)

        let registered = TruthWiki.parse(try F.text("valid/ledger.jsonl"), options: TruthReadOptions(signers: try F.signers()))
        #expect(registered.held.isEmpty)
        #expect(TruthWiki.statusTable(registered.entries) == want)
    }

    @Test("valid/ledger.jsonl re-serializes every entry line byte for byte, and keeps every line verbatim")
    func ledgerVerbatim() throws {
        let lines = try F.lines("valid/ledger.jsonl")
        let result = TruthWiki.parse(lines: lines)
        let entryLines = lines.filter { ["TB", "UV"].contains(F.string(F.object($0)["type"])) }
        #expect(TruthWiki.serialize(result.entries) == entryLines)
        #expect(result.lines.map(\.text) == lines)
        #expect(lines.count == 19)
        #expect(result.head == TruthStreamHead(seq: 19, hash: F.string(F.object(lines[18])["hash"])!))
    }

    @Test("valid/ledger.jsonl: current truth, struck and overridden TBs never object, and the contest rides its TB until resolved")
    func ledgerSelection() throws {
        let result = TruthWiki.parse(try F.text("valid/ledger.jsonl"))
        let selection = TruthWiki.selectCurrentTruth(result.entries)
        // The last is the TB two agent sessions' drafts minted by quorum
        #expect(selection.groundTruth.map(\.id) == ["01M1E6JK84NECBQZ8GX9C7H1KA", "01M1E6JK8BVGAAP733SN0VCW9W", "01M1E6JK8KR7Z4VAZ1GM8KFSQT"])
        #expect(selection.contested.isEmpty)
        #expect(selection.unverified.map(\.id) == ["01M1E6JK81TR57BA191BG8Y0Q3"])
        let tombstones = result.entries.compactMap { entry -> TruthTbEntry? in
            if case .tb(let tb) = entry { return tb } else { return nil }
        }
        // LOG_BUDGET's TB was overridden: its literals no longer object
        #expect(TruthObjections.check("set LOG_BUDGET = 30", against: tombstones).isEmpty)
        #expect(TruthObjections.check("call fetchV1 here", against: tombstones).map(\.tombstone.id) == ["01M1E6JK8BVGAAP733SN0VCW9W"])

        // Up to seq 4 the TB is contested and its open UV rides it
        let partial = TruthWiki.parse(lines: Array(try F.lines("valid/ledger.jsonl").prefix(4)))
        let early = TruthWiki.selectCurrentTruth(partial.entries)
        #expect(early.contested.map(\.tombstone.id) == ["01M1E6JK80P9Y3CMA9HBZEND9H"])
        #expect(early.contested.first?.contestedBy.map(\.id) == ["01M1E6JK82QWPK6VS437JKMJPZ"])
        let section = TruthCompaction.renderSection(early)
        #expect(section.components(separatedBy: "LOG_BUDGET went back to 30 in the hotfix.").count == 2, "rendered once, beside its TB")
    }

    @Test("valid/proposals.jsonl: passes the schema and the codec, chains, and is refused as a wiki stream")
    func proposals() throws {
        let lines = try F.lines("valid/proposals.jsonl")
        var decoded: [DecodedTruthLine?] = []
        for line in lines {
            #expect(F.schemaValid(line))
            let d = try TruthFormat.decode(line)
            #expect(d.version == 2 && d.type == .proposal)
            decoded.append(d)
        }
        #expect(TruthFormat.checkChain(decoded).isEmpty)
        let expected = F.array(try F.json("valid/proposals.expected.json"))
        let filedAs = ["tombstone": "tb", "uv": "uv"]
        #expect(lines.map { F.string(F.object($0)["kind"]) } == expected.map { item -> String? in
            guard case .dict(let w) = item else { return nil }
            return F.string(w["kind"]).flatMap { filedAs[$0] }
        })

        let asWiki = TruthWiki.parse(lines: lines)
        #expect(asWiki.refused && asWiki.entries.isEmpty)
    }

    @Test("valid/proposals.jsonl: the envelope writer reproduces the golden lines byte for byte")
    func proposalWriter() throws {
        let lines = try F.lines("valid/proposals.jsonl")
        let tb = try TruthProposalEnvelope(
            id: "01J9PROPTB0000000000000000",
            ts: "2026-09-01T10:20:00.000Z",
            author: "detector:short-hand",
            draft: .tb(
                claim: "MAX_RETRIES 3 is dead; it is 5.",
                evidence: [TruthEvidence(kind: .message, ref: "msg_0101", detail: "user correction")],
                literals: [TruthTombstonedLiteral(dead: "3", subject: "MAX_RETRIES", current: "5")]
            ),
            targetRef: "shorthand:tombstone:msg_0101",
            signal: .init(source: "compaction-candidate", detail: "short-hand correction")
        )
        let uv = try TruthProposalEnvelope(
            id: "01J9PROPUV0000000000000000",
            ts: "2026-09-01T10:21:00.000Z",
            author: "agent:claude-code",
            draft: .uv(assertion: "The cache is shared across tenants.", basis: "a trace", verifyBy: TruthVerifyBy(kind: .inspect, value: "src/cache.ts"), contests: nil),
            signal: .init(source: "agent"),
            agentSessionId: "sess_7f3a"
        )
        #expect(try TruthFormat.chain([tb.body, uv.body]) == Array(lines.prefix(2)))

        // An evidence kind and signal source this version doesn't know are written as given
        let unknown = try TruthProposalEnvelope(
            id: "01J9PROPTB0000000000000001",
            ts: "2026-09-01T10:23:00.000Z",
            author: "agent:claude-code",
            draft: .tb(
                claim: "MAX_RETRIES 3 is dead; it is 7.",
                evidence: [TruthEvidence(kind: "url", ref: "https://example.com/runbook#retries")],
                literals: [TruthTombstonedLiteral(dead: "3", subject: "MAX_RETRIES", current: "7")]
            ),
            targetRef: "shorthand:tombstone:msg_0101",
            signal: .init(source: "human-review"),
            agentSessionId: "sess_7f3a"
        )
        let third = F.object(lines[2])
        let head = TruthStreamHead(seq: 3, hash: F.string(third["hash"])!)
        #expect(try unknown.line(after: head) == lines[3])
    }

    @Test("valid/unknown.jsonl: passes the schema and the codec, and folds with unknown statuses failing closed")
    func unknownValues() throws {
        let lines = try F.lines("valid/unknown.jsonl")
        for line in lines {
            #expect(F.schemaValid(line))
            #expect(throws: Never.self) { try TruthFormat.decode(line) }
        }
        guard case .dict(let want) = try F.json("valid/unknown.expected.json"), let fold = want["fold"] else {
            Issue.record("unknown.expected.json has no fold")
            return
        }
        let result = TruthWiki.parse(lines: lines)
        #expect(result.errors.isEmpty)
        #expect(TruthWiki.statusTable(result.entries) == F.table(fold))
    }

    @Test("valid/unknown.jsonl: keeps every line verbatim — an unknown field, unknown statuses, kinds and cause")
    func unknownVerbatim() throws {
        let lines = try F.lines("valid/unknown.jsonl")
        let result = TruthWiki.parse(lines: lines)
        let entryLines = lines.filter { ["TB", "UV"].contains(F.string(F.object($0)["type"])) }
        #expect(TruthWiki.serialize(result.entries) == entryLines)
        #expect(result.transitions.map(\.status) == ["archived"])
        #expect(result.transitions.first?.causeKind == "archive" && result.transitions.first?.causeRef == nil)
        guard case .tb(let tb1)? = result.entries.first(where: { $0.id == "01J9UNKNOWNTB00000000000001" }) else {
            Issue.record("TB 1 missing")
            return
        }
        #expect(tb1.extra["reviewers"] == .array([.string("sam")]))
        #expect(tb1.source?.lineStatus == "active")
        #expect(tb1.status?.rawValue == "archived")
        guard case .tb(let tb3)? = result.entries.first(where: { $0.id == "01J9UNKNOWNTB00000000000003" }) else {
            Issue.record("TB 3 missing")
            return
        }
        #expect(tb3.evidence.map(\.kind.rawValue) == ["url"])
    }

    @Test("valid/unknown.jsonl: stenographer's import outcomes, as a reader sees them")
    func unknownImportOutcomes() throws {
        // 'inserted' and 'unknown-value' lines are read and keep their line's
        // status (evidence and verifyBy kinds are not a reader's to judge);
        // 'unknown-status' lines are history; the 'held' TRANSITION is kept
        // and moves its target to a status no one knows, which fails closed.
        let lines = try F.lines("valid/unknown.jsonl")
        let result = TruthWiki.parse(lines: lines)
        guard case .dict(let want) = try F.json("valid/unknown.expected.json"), let outcomes = want["import"] else {
            Issue.record("unknown.expected.json has no import")
            return
        }
        for case .dict(let w) in F.array(outcomes) {
            let n = try #require(F.int(w["line"]))
            let line = F.object(lines[n - 1])
            if F.string(line["type"]) == "TRANSITION" {
                #expect(F.string(w["outcome"]) == "held")
                let target = try #require(result.entries.first { $0.id == F.string(line["target"]) })
                #expect(target.statusValue == F.string(line["status"]))
                #expect(TruthWiki.classify(target) == .history)
                continue
            }
            let entry = try #require(result.entries.first { $0.id == F.string(line["id"]) })
            if F.string(w["outcome"]) == "proposal", F.string(w["reason"]) == "unknown-status" {
                #expect(TruthWiki.classify(entry) == .history, "line \(n)")
            } else {
                #expect(entry.source?.lineStatus == F.string(line["status"]), "line \(n)")
            }
        }
    }

    @Test("valid/routing.jsonl: each line read on its own as routing.expected.json says")
    func routing() throws {
        let lines = try F.lines("valid/routing.jsonl")
        let signers = try F.signers()
        for case .dict(let w) in F.array(try F.json("valid/routing.expected.json")) {
            let n = try #require(F.int(w["line"]))
            let line = lines[n - 1]
            #expect(F.schemaValid(line), "line \(n)")
            // A single line part-way through a stream is a valid partial stream
            let result = TruthWiki.parse(lines: [line], options: TruthReadOptions(signers: signers))
            #expect(result.errors.isEmpty, "line \(n): \(result.errors)")
            let entry = result.entries.first { $0.id == F.string(F.object(line)["id"]) }
            switch F.string(w["outcome"]) {
            case "inserted":
                #expect(entry?.statusValue == F.string(w["status"]), "line \(n)")
            case "proposal":
                #expect(entry.map(TruthWiki.classify) == .history, "line \(n)")
                #expect(entry?.inadmissible?.reason.rawValue == F.string(w["reason"]), "line \(n)")
            default:
                // held: an ADDENDUM changes nothing for a reader; only TRANSITIONs move statuses
                #expect(entry == nil && result.transitions.isEmpty, "line \(n)")
            }
        }
    }

    @Test("valid/routing.jsonl: without a signer registry, an identity that passes the identity rules is accepted, and an agent is an `agent:` key")
    func routingWithoutRegistry() throws {
        let lines = try F.lines("valid/routing.jsonl")
        let mallory = TruthWiki.parse(lines: [lines[1]])
        #expect(mallory.entries.map(TruthWiki.classify) == [.groundTruth])
        // A TB an agent signed alone is not truth without a registry either
        let agentAlone = TruthWiki.parse(lines: [lines[5]])
        #expect(F.string(F.object(lines[5])["signedBy"]) == "agent:claude-code")
        #expect(agentAlone.entries.first?.inadmissible?.reason == .agentWithoutQuorum)
    }

    // MARK: v1/

    @Test("v1/legacy.jsonl: 0.x lines decode as version 1 and read as legacy.expected.json says")
    func legacy() throws {
        let lines = try F.lines("v1/legacy.jsonl")
        for line in lines {
            #expect(try TruthFormat.decode(line).version == 1)
            #expect(!F.schemaValid(line))
        }
        let result = TruthWiki.parse(lines: lines, options: TruthReadOptions(signers: try F.signers()))
        #expect(result.errors.isEmpty)
        for case .dict(let w) in F.array(try F.json("v1/legacy.expected.json")) {
            let n = try #require(F.int(w["line"]))
            let entry = try #require(result.entries.first { $0.id == F.string(F.object(lines[n - 1])["id"]) })
            if F.string(w["outcome"]) == "inserted" {
                #expect(entry.statusValue == F.string(w["status"]), "line \(n)")
                continue
            }
            // A v1 TB carries no hash: never truth on its own (filed for a person to sign)
            #expect(entry.inadmissible?.reason.rawValue == F.string(w["reason"]), "line \(n)")
            #expect(TruthWiki.classify(entry) == .history, "line \(n)")
            if let kinds = w["draftEvidenceKinds"], case .tb(let tb) = entry {
                #expect(tb.evidence.map { AnyCodableValue.string($0.kind.rawValue) } == F.array(kinds), "line \(n)")
            }
        }
        // The lines themselves are never rewritten: 'command' stays 'command' on the wire
        #expect(TruthWiki.serialize(result.entries) == lines)
    }

    // MARK: invalid/

    @Test("invalid/schema.jsonl: the codec refuses every line, and so does the schema")
    func invalidSchema() throws {
        let lines = try F.lines("invalid/schema.jsonl")
        let want = F.array(try F.json("invalid/schema.expected.json"))
        #expect(want.count == lines.count)
        for (i, line) in lines.enumerated() {
            guard case .dict(let w) = want[i], let reason = F.string(w["reason"]) else { continue }
            #expect(throws: TruthLineError.self, "line \(i + 1) (\(reason))") { try TruthFormat.decode(line) }
            // SmallChatCore's validator doesn't assert `format` (an annotation in
            // 2020-12): a date that doesn't exist passes its schema check, and the codec refuses it.
            let formatOnly = reason.contains("February 30") || reason.contains("24:00")
            #expect(F.schemaValid(line) == formatOnly, "line \(i + 1) (\(reason))")
        }
    }

    @Test("invalid/codec.jsonl: the schema accepts every line and the codec refuses it with the expected error")
    func invalidCodec() throws {
        let lines = try F.lines("invalid/codec.jsonl")
        let want = F.array(try F.json("invalid/codec.expected.json"))
        #expect(want.count == lines.count)
        for (i, line) in lines.enumerated() {
            guard case .dict(let w) = want[i], let reason = F.string(w["reason"]), let pattern = F.string(w["error"]) else { continue }
            #expect(F.schemaValid(line), "line \(i + 1) (\(reason))")
            do {
                _ = try TruthFormat.decode(line)
                Issue.record("line \(i + 1) (\(reason)) was accepted")
            } catch {
                let message = String(describing: error)
                #expect(message.range(of: pattern, options: .regularExpression) != nil, "line \(i + 1) (\(reason)): \(message)")
            }
        }
    }

    @Test("invalid/chain-*.jsonl: valid lines that are not one stream; the reader refuses the file")
    func invalidChains() throws {
        guard case .dict(let chains) = try F.json("invalid/chain.expected.json") else {
            Issue.record("chain.expected.json is not an object")
            return
        }
        for (file, wanted) in chains {
            let lines = try F.lines("invalid/\(file)")
            for line in lines { #expect(F.schemaValid(line), "\(file)") }
            let result = TruthWiki.parse(lines: lines)
            #expect(result.refused && result.entries.isEmpty, "\(file)")
            for case .dict(let w) in F.array(wanted) {
                let n = F.int(w["line"])
                let prefix = F.string(w["error"]) ?? "?"
                #expect(result.errors.contains { $0.line == n && $0.error.hasPrefix(prefix) }, "\(file) line \(n ?? 0): \(result.errors)")
            }
        }
    }

    // MARK: Timestamps

    private func withTs(_ ts: String) throws -> String {
        var line = F.object(try F.lines("valid/ledger.jsonl")[0])
        line["ts"] = .string(ts)
        line["hash"] = .string(try TruthFormat.hash(line))
        return try canonicalJSON(.dict(line))
    }

    @Test("timestamps: a leap second and impossible dates are refused, ordinary ones read")
    func timestamps() throws {
        for ts in ["2026-09-01T10:00:60.000Z", "2026-09-01T23:59:60Z", "2026-09-01T23:59:60.5+00:00"] {
            #expect(throws: TruthLineError("ts: a leap second (:60) is not a time this codec reads")) { try TruthFormat.decode(try withTs(ts)) }
        }
        for ts in ["2026-02-30T00:00:00Z", "2026-09-01T24:00:00Z", "2026-09-01T10:00:00+24:00", "2026-09-01t10:00:00z", "2026-09-01T10:00:00"] {
            #expect(throws: TruthLineError.self, "\(ts)") { try TruthFormat.decode(try withTs(ts)) }
        }
        #expect(try TruthFormat.decode(try withTs("2028-02-29T23:59:59.999+05:30")).version == 2)
    }
}
