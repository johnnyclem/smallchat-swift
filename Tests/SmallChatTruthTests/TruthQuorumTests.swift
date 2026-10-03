import Foundation
import Testing
import SmallChatCore
@testable import SmallChatTruth

// The agent quorum, evidence classes and reserved signer keys of truth
// format v2 (stenographer spec/truth-format: "Agent quorum", "Evidence
// classes", "Identities"). The golden fixtures cover one line per quorum
// rule; these tests pin what a reader does with them, and the edges the
// spec spells out.

/// One evidence item, as JSON text.
private func item(_ kind: String, _ ref: String) -> String {
    #"{"kind":"\#(kind)","ref":"\#(ref)"}"#
}

/// One quorum member, as JSON text.
private func member(_ author: String, _ session: String, _ ts: String, _ evidence: [String], verdict: String? = nil) -> String {
    let verdictField = verdict.map { #","verdict":"\#($0)""# } ?? ""
    return #"{"author":"\#(author)","agentSessionId":"\#(session)","ts":"\#(ts)","evidence":[\#(evidence.joined(separator: ","))]\#(verdictField)}"#
}

private let commitItem = item("commit", "c4fe0b1")
private let fileItem = item("file", "src/api/search.ts:1")
private let claudeAt1013 = member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem])
private let codexAt1014 = member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem])

/// A TB two agent sessions settled together; each argument replaces a part of it.
private func quorumTB(
    author: String = "agent:codex",
    signedBy: String = "agent:codex",
    evidence: [String] = [commitItem, fileItem],
    members: [String] = [claudeAt1013, codexAt1014],
    ts: String = "2026-09-01T10:14:00.000Z",
    literals: String? = #"[{"dead":"searchV1","current":"searchV2"}]"#
) -> String {
    let literalsField = literals.map { #","literals":\#($0)"# } ?? ""
    return #"{"id":"TB-Q","type":"TB","ts":"\#(ts)","author":"\#(author)","claim":"searchV1 is gone; searchV2 replaced it.","evidence":[\#(evidence.joined(separator: ","))],"signedBy":"\#(signedBy)"\#(literalsField),"quorum":[\#(members.joined(separator: ","))],"status":"active"}"#
}

/// An ADDENDUM two agent sessions' verdicts settle; `links` is the `x-steno.links` array, or nil for none.
private func quorumAddendum(
    evidence: [String] = [commitItem, fileItem],
    members: [String],
    links: String? = #"[{"fromId":"AD-Q","toId":"UV-1","type":"verifies"}]"#
) -> String {
    let xSteno = links.map { #","x-steno":{"links":\#($0)}"# } ?? ""
    return #"{"id":"AD-Q","type":"ADDENDUM","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","evidence":[\#(evidence.joined(separator: ","))],"note":null,"quorum":[\#(members.joined(separator: ","))]\#(xSteno)}"#
}

/// The one line of a stream holding `body`.
private func line(_ body: String) -> String {
    chainTruthLines([body])[0]
}

/// The message the codec refuses `body` with, or nil when it reads it.
private func refusal(_ body: String) -> String? {
    do {
        _ = try TruthFormat.decode(line(body))
        return nil
    } catch {
        return String(describing: error)
    }
}

@Suite("Evidence classes")
struct TruthEvidenceClassTests {

    @Test("chat, ticket and doc are known kinds; commit, file, test, claimed-command and wiki settle, the rest ask")
    func classes() {
        #expect(TruthEvidence.Kind.known == [.commit, .file, .test, .command, .claimedCommand, .wiki, .message, .chat, .ticket, .doc])
        #expect(TruthEvidence.Kind.settling == [.commit, .file, .test, .claimedCommand, .wiki])
        #expect([TruthEvidence.Kind.chat, .ticket, .doc].map(\.rawValue) == ["chat", "ticket", "doc"])
        for kind in TruthEvidence.Kind.settling {
            #expect(kind.evidenceClass == .settling, "\(kind)")
            #expect(kind.isKnown)
        }
        // Pre-1.0 command output was never re-run: question-class, like what people said or wrote down
        for kind: TruthEvidence.Kind in [.message, .chat, .ticket, .doc, .command] {
            #expect(kind.evidenceClass == .question, "\(kind)")
            #expect(kind.isKnown)
        }
        // Fail closed: a kind this version doesn't know never settles anything
        for kind: TruthEvidence.Kind in ["screenshot", "url", "benchmark", "Commit"] {
            #expect(kind.evidenceClass == .question, "\(kind)")
            #expect(!kind.isKnown)
        }
        #expect(TruthEvidence(kind: .test, ref: "test/retry.test.ts").isSettling)
        #expect(!TruthEvidence(kind: .ticket, ref: "LIN-42").isSettling)
    }
}

@Suite("Agent quorum")
struct TruthQuorumTests {

    @Test("the consumption rules are stenographer's, word for word: agents file a verdict, and settle only together")
    func consumptionRulesText() {
        #expect(consumptionRules == """
        Consumption rules by confidence type:
        - Active TB: treat as ground truth. A reviewer may block on it; a code agent may rely on it.
        - Contested TB: ground truth with a visible asterisk — cite both the TB and the contesting UV.
        - Open UV: FLAG, DON'T BLOCK. A finding grounded only in a UV is phrased as a question or heads-up, never a demanded change. If your current task can check the UV, file your verdict and evidence with resolve_uv: it settles only when another agent session agrees from a different angle (other evidence, another kind) within 15 minutes, or when a person rules.
        - Refuted UV / overridden TB: retrievable for history, excluded from current-truth by default, never citable as support for a claim.
        """)
    }

    @Test("the window and the floor are the spec's: 15 minutes, two sessions")
    func constants() {
        #expect(TruthQuorum.windowMilliseconds == 900_000)
        #expect(TruthQuorum.minimumMembers == 2)
    }

    // MARK: Admission

    @Test("a TB two agent sessions settled together is truth, and carries its members")
    func quorumTbIsTruth() throws {
        let tb = line(quorumTB())
        let plain = TruthWiki.parse(lines: [tb])
        #expect(plain.errors.isEmpty)
        #expect(plain.entries.map(TruthWiki.classify) == [.groundTruth])
        guard case .tb(let entry)? = plain.entries.first else {
            Issue.record("no TB")
            return
        }
        #expect(entry.quorum?.map(\.agentSessionId) == ["sess_a", "sess_b"])
        #expect(entry.quorum?.map(\.author) == ["agent:claude-code", "agent:codex"])
        #expect(entry.quorum?.first?.evidence == [TruthEvidence(kind: .commit, ref: "c4fe0b1")])
        #expect(entry.quorum?.first?.verdict == nil)
        #expect(entry.extra["quorum"] == nil, "quorum is a field this version defines")
        #expect(TruthWiki.serialize(plain.entries) == [tb])

        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "agent:*", role: .agent)])
        let registered = TruthWiki.parse(lines: [tb], options: TruthReadOptions(signers: signers))
        #expect(registered.entries.map(TruthWiki.classify) == [.groundTruth])
    }

    @Test("an agent's TB without a quorum is never truth (agent-without-quorum), with or without a registry")
    func agentWithoutQuorum() throws {
        let alone = #"{"id":"TB-A","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone.","evidence":[{"kind":"commit","ref":"c4fe0b1"}],"signedBy":"Agent:Codex","literals":[{"dead":"searchV1"}],"status":"active"}"#
        let plain = TruthWiki.parse(lines: [line(alone)])
        #expect(plain.errors.isEmpty)
        #expect(plain.entries.first?.inadmissible?.reason == .agentWithoutQuorum)
        #expect(plain.entries.first?.inadmissible?.reason.rawValue == "agent-without-quorum")
        #expect(plain.entries.map(TruthWiki.classify) == [.history])

        // With a registry, its `agent` role says who is an agent, whatever the name
        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "codex-bot", role: .agent), TruthSigner(id: "kim", role: .human)])
        let byBot = alone.replacingOccurrences(of: "agent:codex", with: "codex-bot").replacingOccurrences(of: "Agent:Codex", with: "codex-bot")
        let registered = TruthWiki.parse(lines: [line(byBot)], options: TruthReadOptions(signers: signers))
        #expect(registered.entries.first?.inadmissible?.reason == .agentWithoutQuorum)

        // A person still signs alone
        let byKim = alone.replacingOccurrences(of: "agent:codex", with: "kim").replacingOccurrences(of: "Agent:Codex", with: "kim")
        #expect(TruthWiki.parse(lines: [line(byKim)], options: TruthReadOptions(signers: signers)).entries.map(TruthWiki.classify) == [.groundTruth])

        // A version 1 TB carries no quorum: an agent's is never truth, even when the host admits v1 TBs
        let v1 = #"{"id":"TB-9","type":"TB","ts":"2026-03-01T09:00:00.000Z","author":"agent:codex","claim":"legacyRetryBudget is gone.","evidence":[{"kind":"commit","ref":"9f2c1ab"}],"signedBy":"agent:codex","status":"active"}"#
        let admitted = TruthWiki.parse(lines: [v1], options: TruthReadOptions(admitV1Tbs: true))
        #expect(admitted.entries.first?.inadmissible?.reason == .agentWithoutQuorum)
    }

    @Test("a quorum whose members aren't all agents settles nothing")
    func membersAreAgents() throws {
        // Without a registry, an agent's key starts with `agent:`
        let withPerson = quorumTB(members: [member("kim", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem]), codexAt1014])
        #expect(refusal(withPerson) == nil, "the codec's rules don't say who is an agent")
        let plain = TruthWiki.parse(lines: [line(withPerson)])
        #expect(plain.entries.first?.inadmissible?.reason == .agentWithoutQuorum)

        // With one, an identity it lists with role `agent`: a person, or a name it doesn't list, is no witness
        let signers = try TruthSignerRegistry(signers: [
            TruthSigner(id: "agent:codex", role: .agent),
            TruthSigner(id: "kim", role: .human),
            TruthSigner(id: "agent:claude-code", role: .agent),
        ])
        #expect(TruthWiki.parse(lines: [line(withPerson)], options: TruthReadOptions(signers: signers)).entries.first?.inadmissible?.reason == .agentWithoutQuorum)
        let unlisted = quorumTB(members: [member("agent:ghost", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem]), codexAt1014])
        #expect(TruthWiki.parse(lines: [line(unlisted)], options: TruthReadOptions(signers: signers)).entries.first?.inadmissible?.reason == .agentWithoutQuorum)
        #expect(TruthWiki.parse(lines: [line(quorumTB())], options: TruthReadOptions(signers: signers)).entries.map(TruthWiki.classify) == [.groundTruth])
    }

    @Test("an evidence kind the reader doesn't know: the line decodes, and settles nothing for this reader")
    func unknownKindFailsClosed() {
        // Member 2 cites only a kind this version doesn't know: it may be a newer writer's settling kind
        let tb = quorumTB(
            evidence: [commitItem, item("benchmark", "bench/search")],
            members: [claudeAt1013, member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [item("benchmark", "bench/search")])]
        )
        #expect(refusal(tb) == nil)
        let read = TruthWiki.parse(lines: [line(tb)])
        #expect(read.errors.isEmpty)
        #expect(read.entries.first?.inadmissible?.reason == .agentWithoutQuorum)
        #expect(read.entries.first?.inadmissible?.detail.contains("benchmark") == true)
        #expect(read.entries.map(TruthWiki.classify) == [.history])

        // An unknown kind beside settling evidence of two known kinds rests nothing on it
        let extra = quorumTB(
            evidence: [commitItem, fileItem, item("benchmark", "bench/search")],
            members: [claudeAt1013, member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem, item("benchmark", "bench/search")])]
        )
        #expect(TruthWiki.parse(lines: [line(extra)]).entries.map(TruthWiki.classify) == [.groundTruth])
    }

    @Test("a quorum is part of a TB's content: two copies with different members are a conflict")
    func quorumIsContent() throws {
        let a = line(quorumTB())
        let otherSession = line(quorumTB(members: [member("agent:claude-code", "sess_c", "2026-09-01T10:13:00.000Z", [commitItem]), codexAt1014]))
        let merged = TruthWiki.parseFiles([("a.jsonl", a), ("b.jsonl", otherSession)])
        #expect(merged.conflicts == [TruthConflict(id: "TB-Q", files: ["a.jsonl", "b.jsonl"])])
        #expect(merged.entries.first?.inadmissible?.reason == .conflict)
        #expect(TruthWiki.parseFiles([("a.jsonl", a), ("b.jsonl", a)]).conflicts.isEmpty)
    }

    @Test("an entry built in code is written in the version 1 shape, which carries no quorum")
    func handBuiltLineHasNoQuorum() throws {
        guard case .tb(var built)? = TruthWiki.parse(lines: [line(quorumTB())]).entries.first else {
            Issue.record("no TB")
            return
        }
        built.source = nil
        let written = try #require(TruthWiki.serialize([.tb(built)]).first)
        #expect(!written.contains("quorum"))
        #expect(try TruthFormat.decode(written).version == 1)
        // Read back, an agent's TB without its quorum is not truth
        #expect(TruthWiki.parse(lines: [written], options: TruthReadOptions(admitV1Tbs: true)).entries.first?.inadmissible?.reason == .agentWithoutQuorum)
    }

    // MARK: Where a quorum may appear

    @Test("a quorum appears only on a v2 TB or ADDENDUM line")
    func onlyTbAndAddendum() {
        let quorum = #""quorum":[\#(claudeAt1013),\#(codexAt1014)]"#
        let uv = #"{"id":"UV-1","type":"UV","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","assertion":"a","basis":"b","verifyBy":{"kind":"ask","value":"ops"},"contests":null,"status":"open",\#(quorum)}"#
        let ruling = #"{"id":"RUL-1","type":"RULING","ts":"2026-09-01T10:14:00.000Z","author":"kim","kind":"strike","opinion":"wrong branch","target":"TB-1",\#(quorum)}"#
        let transition = #"{"id":"T-1","type":"TRANSITION","ts":"2026-09-01T10:14:00.000Z","author":"kim","target":"TB-1","status":"struck","cause":{"kind":"strike","ref":null},\#(quorum)}"#
        let proposal = #"{"id":"P-1","type":"PROPOSAL","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","kind":"tombstone","draft":{},"targetRef":null,"signal":{"source":"agent"},\#(quorum)}"#
        for body in [uv, ruling, transition, proposal] {
            #expect(refusal(body)?.contains("only on TB and ADDENDUM lines") == true, "\(body)")
        }
        let v1 = #"{"id":"TB-9","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone.","evidence":[\#(commitItem)],"signedBy":"agent:codex","literals":[{"dead":"searchV1"}],"status":"active",\#(quorum)}"#
        #expect(throws: TruthLineError.self) { try TruthFormat.decode(v1) }
        #expect(refusal(quorumAddendum(members: [
            member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem], verdict: "verified"),
            member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem], verdict: "verified"),
        ])) == nil)
    }

    // MARK: The rules at their edges

    @Test("rule 1: sessions compare trimmed of White_Space, and U+FEFF is not White_Space")
    func sessionsTrimmed() {
        let a = member("agent:claude-code", "sess_a\u{3000}", "2026-09-01T10:13:00.000Z", [commitItem])
        #expect(refusal(quorumTB(members: [a, member("agent:codex", "sess_a", "2026-09-01T10:14:00.000Z", [fileItem])]))?.contains("share agent session") == true)
        let bom = member("agent:claude-code", "sess_b\u{FEFF}", "2026-09-01T10:13:00.000Z", [commitItem])
        #expect(refusal(quorumTB(members: [bom, codexAt1014])) == nil)
        let blank = member("agent:claude-code", "\u{0085}\u{00A0}", "2026-09-01T10:13:00.000Z", [commitItem])
        #expect(refusal(quorumTB(members: [blank, codexAt1014]))?.contains("names no agent session") == true)
        #expect(refusal(quorumTB(members: [codexAt1014]))?.contains("at least 2 members") == true)
    }

    @Test("rule 2: the writer is a member, and signs its TB, compared by key")
    func writerIsMember() {
        #expect(refusal(quorumTB(author: "Agent:Codex", signedBy: "agent:codex")) == nil)
        #expect(refusal(quorumTB(author: "agent:other", signedBy: "agent:other"))?.contains("is not a quorum member") == true)
        #expect(refusal(quorumTB(signedBy: "agent:claude-code"))?.contains("signed by its author") == true)
    }

    @Test("rule 3: one piece of evidence in two spellings is one item; a leading / and the ref's kind still count")
    func evidenceSpellings() {
        // Each member also cites an item of its own, of a kind the other doesn't, so only the pair is in question
        func pair(_ first: String, _ second: String) -> String {
            let own = (item("test", "test/a.test.ts"), item("wiki", "TB-0"))
            return quorumTB(
                evidence: [first, own.0, second, own.1],
                members: [
                    member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [first, own.0]),
                    member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [second, own.1]),
                ]
            )
        }
        #expect(refusal(pair(item("file", "src\\\\api//./x.ts:3"), item("file", "src/api/x.ts:3")))?.contains("both cite file") == true)
        #expect(refusal(pair(item("file", "/src/x.ts"), item("file", "src/x.ts"))) == nil, "a leading / stays")
        #expect(refusal(pair(item("test", "retry\\t budget"), item("test", "retry budget")))?.contains("both cite test") == true)
        #expect(refusal(pair(item("commit", "C4FE0B1"), item("commit", "c4fe0b1d99")))?.contains("both cite commit") == true)
        #expect(refusal(pair(item("wiki", "TB-1"), item("wiki", "tb-1"))) == nil, "only a commit compares case-folded")
        #expect(refusal(pair(item("commit", "c4fe0b1"), item("wiki", "c4fe0b1"))) == nil, "items of different kinds differ")
    }

    @Test("rule 3: settling evidence from every member, and two settling kinds across them")
    func differentAngles() {
        let chatOnly = member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [item("chat", "slack://C1/p1")])
        #expect(refusal(quorumTB(evidence: [item("chat", "slack://C1/p1"), fileItem], members: [chatOnly, codexAt1014]))?.contains("cites no settling evidence") == true)
        let twoCommits = quorumTB(
            evidence: [commitItem, item("commit", "aa11bb2")],
            members: [claudeAt1013, member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [item("commit", "aa11bb2")])]
        )
        #expect(refusal(twoCommits)?.contains("two settling kinds") == true)
    }

    @Test("rule 4: 15 minutes to the millisecond, the line's own ts included")
    func sameTime() {
        let early = member("agent:claude-code", "sess_a", "2026-09-01T09:59:00.000Z", [commitItem])
        #expect(refusal(quorumTB(members: [early, codexAt1014])) == nil, "900 000 ms is within the window")
        let earlier = member("agent:claude-code", "sess_a", "2026-09-01T09:58:59.999Z", [commitItem])
        #expect(refusal(quorumTB(members: [earlier, codexAt1014]))?.contains("900001 ms") == true)
        // Offsets are read: 11:13+01:00 is 10:13Z
        let offset = member("agent:claude-code", "sess_a", "2026-09-01T11:13:00+01:00", [commitItem])
        #expect(refusal(quorumTB(members: [offset, codexAt1014])) == nil)
        #expect(refusal(quorumTB(ts: "2026-09-01T10:28:00.001Z"))?.contains("more than 15 minutes") == true)
        let bad = member("agent:claude-code", "sess_a", "2026-09-01 10:13", [commitItem])
        #expect(refusal(quorumTB(members: [bad, codexAt1014])) != nil)
    }

    @Test("rule 5: an ADDENDUM's verdicts agree with each other and with its links; a TB names its literals")
    func agreeing() {
        let verified = [
            member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem], verdict: "verified"),
            member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem], verdict: "verified"),
        ]
        let split = [verified[0], member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem], verdict: "refuted")]
        #expect(refusal(quorumAddendum(members: split, links: nil))?.contains("disagree") == true, "no links: verdicts still agree")
        #expect(refusal(quorumAddendum(members: verified, links: nil)) == nil)
        #expect(refusal(quorumAddendum(members: verified, links: "[]")) == nil)
        #expect(refusal(quorumAddendum(members: verified, links: #"[{"fromId":"AD-Q","toId":"UV-1","type":"corroborates"}]"#)) == nil)
        #expect(refusal(quorumAddendum(members: verified, links: #"[{"fromId":"AD-Q","toId":"UV-1","type":"refutes"}]"#))?.contains("verdict verified") == true)
        let unverdicted = [member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem]), verified[1]]
        #expect(refusal(quorumAddendum(members: unverdicted)) != nil)
        #expect(refusal(quorumTB(literals: nil))?.contains("literals") == true)
    }

    @Test("rule 6: the line shows each member's items as the member cited them, and no others")
    func lineShowsEvidence() {
        #expect(refusal(quorumTB(evidence: [commitItem]))?.contains("lacks quorum member 2") == true)
        #expect(refusal(quorumTB(evidence: [commitItem, fileItem, item("test", "t")]))?.contains("no quorum member cites") == true)
        // Rule 6 trims refs but doesn't normalize them
        #expect(refusal(quorumTB(evidence: [item("commit", " c4fe0b1\u{2003}"), fileItem])) == nil)
        #expect(refusal(quorumTB(evidence: [item("commit", "C4FE0B1"), fileItem])) != nil)
    }

    // MARK: Agreeing with stenographer's reading, code unit for code unit

    @Test("SW-QUORUM-3: a leading U+FEFF belongs to its string: a session, a ref, and the line's hash")
    func leadingByteOrderMark() throws {
        // Rule 1: \u{FEFF}sess_b and sess_b are two sessions (U+FEFF is not White_Space)
        let bom = member("agent:claude-code", "\u{FEFF}sess_b", "2026-09-01T10:13:00.000Z", [commitItem])
        #expect(refusal(quorumTB(members: [bom, codexAt1014])) == nil)

        // A line whose string starts with U+FEFF hashes with it, as every codec hashes it.
        // The body is already in JCS form, so its hash is the SHA-256 of its own bytes.
        let jcs = "{\"assertion\":\"\u{FEFF}searchV1 is gone\",\"author\":\"kim\",\"basis\":\"\u{FEFF}the release notes\",\"contests\":null,\"id\":\"UV-1\",\"prevHash\":null,\"schemaVersion\":2,\"seq\":1,\"status\":\"open\",\"ts\":\"2026-09-01T10:14:00.000Z\",\"type\":\"UV\",\"verifyBy\":{\"kind\":\"ask\",\"value\":\"ops\"}}"
        let hash = sha256Hex(Array(jcs.utf8))
        let text = String(jcs.dropLast()) + ",\"hash\":\"\(hash)\"}"
        #expect(try TruthFormat.hash(line: text) == hash)
        let decoded = try TruthFormat.decode(text)
        #expect(decoded.version == 2)
        let read = TruthWiki.parse(lines: [text])
        #expect(read.errors.isEmpty)
        #expect(TruthWiki.serialize(read.entries) == [text])
    }
}

@Suite("Signer registry keys")
struct TruthSignerKeyTests {

    @Test("signers.json may list public keys: a 1.0 reader accepts them and ignores them")
    func keysIgnored() throws {
        let registry = try TruthSignerRegistry(json: Data(#"""
        {"signers":[
          {"id":"johnnyclem","role":"human","keys":[{"alg":"ed25519","id":"johnnyclem/2026-09","publicKey":"vwK0Oit9S-qSuXboNLd6z8x_ZT3Cikae7d8UUSPaxoE"}]},
          {"id":"agent:*","role":"agent","keys":[]}
        ]}
        """#.utf8))
        #expect(registry.lookup("JohnnyClem")?.role == .human)
        #expect(registry.lookup("agent:codex")?.role == .agent)

        // The fixtures' registry lists a key, and reads as before
        let fixture = try TruthSignerRegistry(json: try TruthFixtures.data("signers.json"))
        #expect(String(decoding: try TruthFixtures.data("signers.json"), as: UTF8.self).contains("\"keys\""))
        #expect(fixture.lookup("johnnyclem")?.role == .human)
    }
}
