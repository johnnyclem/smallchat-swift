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

    @Test("SW-QUORUM-4: an agent's TB citing an evidence kind the reader doesn't know decodes, and is never truth (unknown-value), however well its quorum keeps rule 3")
    func unknownKindFailsClosed() throws {
        // The codec keeps these lines (an unknown kind may be a newer writer's settling kind, so it
        // breaks no rule); a reader that admits truth fails closed on them, as stenographer's import
        // files them: unknown-value, never agent-without-quorum, with or without a registry
        let bench = item("benchmark", "bench/search")
        let shot = item("screenshot", "shot.png")
        let shapes: [(name: String, first: [String], second: [String], kind: String)] = [
            ("member 2 cites only an unknown kind", [commitItem], [bench], "benchmark"),
            ("no member cites a known settling kind", [shot], [bench], "screenshot"),
            ("two known settling kinds, and an unknown one beside them", [commitItem], [fileItem, bench], "benchmark"),
            ("one settling kind, and an unknown item clears rule 3", [commitItem], [item("commit", "9a8b7c6"), item("vibes", "v")], "vibes"),
            ("a known question kind beside an invented one", [commitItem], [item("message", "msg_1"), bench], "benchmark"),
        ]
        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "agent:*", role: .agent), TruthSigner(id: "kim", role: .human)])
        for shape in shapes {
            let tb = quorumTB(
                evidence: shape.first + shape.second,
                members: [
                    member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", shape.first),
                    member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", shape.second),
                ]
            )
            #expect(refusal(tb) == nil, "\(shape.name)")
            for options in [TruthReadOptions(), TruthReadOptions(signers: signers)] {
                let read = TruthWiki.parse(lines: [line(tb)], options: options)
                #expect(read.errors.isEmpty, "\(shape.name)")
                #expect(read.entries.first?.inadmissible?.reason == .unknownValue, "\(shape.name)")
                #expect(read.entries.first?.inadmissible?.reason.rawValue == "unknown-value", "\(shape.name)")
                #expect(read.entries.first?.inadmissible?.detail.contains("evidence kind '\(shape.kind)'") == true, "\(shape.name)")
                #expect(read.entries.map(TruthWiki.classify) == [.history], "\(shape.name)")
            }
        }

        // Weighed ahead of the quorum check: an agent's TB without one, citing an unknown kind, is unknown-value too
        let alone = #"{"id":"TB-A","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone.","evidence":[\#(commitItem),\#(bench)],"signedBy":"agent:codex","literals":[{"dead":"searchV1"}],"status":"active"}"#
        #expect(TruthWiki.parse(lines: [line(alone)]).entries.first?.inadmissible?.reason == .unknownValue)

        // The classes bind agents only: a person may sign on evidence of any class, a kind this version doesn't know included
        let byKim = #"{"id":"TB-K","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"kim","claim":"searchV1 is gone.","evidence":[\#(shot)],"signedBy":"kim","literals":[{"dead":"searchV1"}],"status":"active"}"#
        #expect(TruthWiki.parse(lines: [line(byKim)], options: TruthReadOptions(signers: signers)).entries.map(TruthWiki.classify) == [.groundTruth])
    }

    @Test("SW-QUORUM-6: an agent's TB carrying a link type the reader doesn't know decodes, and is never truth (unknown-value)")
    func unknownLinkTypeFailsClosed() throws {
        // Case 148 of the three-way differential run, verbatim. The quorum rules read the link types a
        // reader knows, so a quorum line carrying an unknown one is kept, and a reader that admits truth
        // fails closed on it (spec: "Unknown values"): stenographer files it as unknown-value
        let tb148 = #"{"schemaVersion":2,"seq":1,"id":"TBQ","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone; searchV2 replaced it.","evidence":[{"kind":"commit","ref":"c4fe0b1"},{"kind":"file","ref":"src/api/search.ts:1"}],"signedBy":"agent:codex","literals":[{"dead":"searchV1","current":"searchV2"}],"quorum":[{"author":"agent:claude-code","agentSessionId":"sess_a","ts":"2026-09-01T10:13:00.000Z","evidence":[{"kind":"commit","ref":"c4fe0b1"}]},{"author":"agent:codex","agentSessionId":"sess_b","ts":"2026-09-01T10:14:00.000Z","evidence":[{"kind":"file","ref":"src/api/search.ts:1"}]}],"status":"active","x-steno":{"origin":"local","provenance":{"kind":"manual"},"agentSessionId":null,"targetRef":null,"links":[{"fromId":"TBQ","toId":"TB-OLD","type":"corroborates"}]},"prevHash":null,"hash":"54d5e9586a8e05541d5141f3c326f7f7289bcbe7753816e35f4dfb7382f133b4"}"#
        #expect(try TruthFormat.hash(line: tb148) == "54d5e9586a8e05541d5141f3c326f7f7289bcbe7753816e35f4dfb7382f133b4")
        #expect(throws: Never.self) { try TruthFormat.decode(tb148) }
        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "agent:*", role: .agent), TruthSigner(id: "kim", role: .human)])
        for options in [TruthReadOptions(), TruthReadOptions(signers: signers)] {
            let read = TruthWiki.parse(lines: [tb148], options: options)
            #expect(read.errors.isEmpty)
            #expect(read.entries.first?.inadmissible?.reason == .unknownValue)
            #expect(read.entries.first?.inadmissible?.detail.contains("link type 'corroborates'") == true)
            #expect(read.entries.map(TruthWiki.classify) == [.history])
            // Kept as written all the same
            #expect(TruthWiki.serialize(read.entries) == [tb148])
        }

        // Beside known links, and weighed ahead of the quorum check: an agent's TB without one is unknown-value too
        let withSigns = quorumTB().replacingOccurrences(
            of: #","status":"active"}"#,
            with: #","status":"active","x-steno":{"links":[{"fromId":"TB-Q","toId":"PROP-1","type":"signs"},{"fromId":"TB-OLD","toId":"TB-Q","type":"corroborates"}]}}"#
        )
        #expect(refusal(withSigns) == nil)
        #expect(TruthWiki.parse(lines: [line(withSigns)]).entries.first?.inadmissible?.reason == .unknownValue)
        let alone = #"{"id":"TB-A","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone.","evidence":[\#(commitItem)],"signedBy":"agent:codex","literals":[{"dead":"searchV1"}],"status":"active","x-steno":{"links":[{"fromId":"TB-A","toId":"TB-OLD","type":"corroborates"}]}}"#
        #expect(TruthWiki.parse(lines: [line(alone)]).entries.first?.inadmissible?.reason == .unknownValue)

        // Known link types only: the same quorum TB is truth
        let known = quorumTB().replacingOccurrences(
            of: #","status":"active"}"#,
            with: #","status":"active","x-steno":{"links":[{"fromId":"TB-Q","toId":"PROP-1","type":"signs"}]}}"#
        )
        #expect(TruthWiki.parse(lines: [line(known)], options: TruthReadOptions(signers: signers)).entries.map(TruthWiki.classify) == [.groundTruth])

        // A person's TB is a person's act: a reader keeps its unknown link and reads its status, as for an unknown kind
        let byKim = #"{"id":"TB-K","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"kim","claim":"searchV1 is gone.","evidence":[\#(commitItem)],"signedBy":"kim","literals":[{"dead":"searchV1"}],"status":"active","x-steno":{"links":[{"fromId":"TB-K","toId":"TB-OLD","type":"corroborates"}]}}"#
        #expect(TruthWiki.parse(lines: [line(byKim)], options: TruthReadOptions(signers: signers)).entries.map(TruthWiki.classify) == [.groundTruth])
    }

    @Test("an agent quorum's ADDENDUM citing an evidence kind the reader doesn't know decodes, and settles nothing by itself")
    func unknownKindAddendum() {
        // A reader never applies an ADDENDUM: it is a cause, kept in `lines`; only a TRANSITION moves a status
        let bench = item("benchmark", "bench/search")
        let addendum = quorumAddendum(
            evidence: [commitItem, bench],
            members: [
                member("agent:claude-code", "sess_a", "2026-09-01T10:13:00.000Z", [commitItem], verdict: "verified"),
                member("agent:codex", "sess_b", "2026-09-01T10:14:00.000Z", [bench], verdict: "verified"),
            ]
        )
        #expect(refusal(addendum) == nil)
        let uv = #"{"id":"UV-1","type":"UV","ts":"2026-09-01T10:00:00.000Z","author":"sam","assertion":"searchV1 is still called.","basis":"a log line","verifyBy":{"kind":"ask","value":"ops"},"contests":null,"status":"open"}"#
        let read = TruthWiki.parse(lines: chainTruthLines([uv, addendum]))
        #expect(read.errors.isEmpty)
        #expect(read.lines.map(\.type) == [.uv, .addendum])
        #expect(read.transitions.isEmpty && read.held.isEmpty)
        #expect(read.entries.map(\.statusValue) == ["open"])
        #expect(read.entries.map(TruthWiki.classify) == [.flag])
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

    @Test("SW-QUORUM-1: the agent: and detector: prefixes compare code point for code point, as stenographer's startsWith does")
    func prefixesByCodePoint() throws {
        // `:` and a combining mark, or an emoji modifier, are one Character, but the key still starts with `agent:`
        for spelling in ["agent:\u{0301}claude-code", "agent:\u{1F3FB}claude-code"] {
            let scalars = "\(spelling.unicodeScalars.map { String($0.value, radix: 16) })"
            #expect(TruthQuorum.isAgent(spelling, signers: nil), "\(scalars)")
            let alone = #"{"id":"TB-A","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"\#(spelling)","claim":"searchV1 is gone.","evidence":[{"kind":"commit","ref":"c4fe0b1"}],"signedBy":"\#(spelling)","literals":[{"dead":"searchV1"}],"status":"active"}"#
            let read = TruthWiki.parse(lines: [line(alone)])
            #expect(read.errors.isEmpty, "\(scalars)")
            #expect(read.entries.first?.inadmissible?.reason == .agentWithoutQuorum, "\(scalars): signed alone, without a quorum")
            #expect(read.entries.map(TruthWiki.classify) == [.history], "\(scalars)")

            // As a member, it is an agent's session
            let together = quorumTB(members: [member(spelling, "sess_a", "2026-09-01T10:13:00.000Z", [commitItem]), codexAt1014])
            #expect(TruthWiki.parse(lines: [line(together)]).entries.map(TruthWiki.classify) == [.groundTruth], "\(scalars)")
        }

        // A registry's `agent:*` lists it too
        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "agent:*", role: .agent)])
        #expect(signers.lookup("agent:\u{0301}claude-code")?.role == .agent)
        // A `*` after a prepended mark (one Character with it) still ends a prefix entry
        let prepended = try TruthSignerRegistry(signers: [TruthSigner(id: "bot\u{0600}*", role: .agent)])
        #expect(prepended.lookup("bot\u{0600}x")?.role == .agent)

        // `detector:` is reserved whatever follows the colon
        #expect(isReservedIdentity("detector:\u{0301}scan"))
        #expect(identityIssue("detector:\u{0301}scan") != nil)
        #expect(identityIssue("detector:\u{0301}scan", allowDetector: true) == nil)
    }

    @Test("SW-QUORUM-2: keys and commit refs lowercase as ECMAScript's toLowerCase does: a word-final Σ is ς")
    func finalSigma() {
        // Expected values are node 22's String.prototype.toLowerCase
        let cases: [(String, String)] = [
            ("Σ", "σ"), ("AΣ", "aς"), ("AΣA", "aσa"), ("AΣ.", "aς."), ("AΣ'A", "aσ'a"), ("A.Σ", "a.ς"),
            ("\u{02B0}Σ", "\u{02B0}σ"), ("1Σ", "1σ"), ("AΣ1", "aς1"), ("AΣ\u{0301}", "aς\u{0301}"),
            ("AΣ\u{0301}A", "aσ\u{0301}a"), ("ΣΣ", "σς"), (" Σ", " σ"), ("\u{0345}Σ", "\u{0345}σ"),
            ("AΣ\u{0345}", "aς\u{0345}"), ("\u{2163}Σ", "\u{2173}ς"), ("ΟΔΥΣΣΕΥΣ", "οδυσσευς"), ("abcΣ", "abcς"),
        ]
        for (input, expected) in cases {
            #expect(ecmaScriptLowercased(input).unicodeScalars.elementsEqual(expected.unicodeScalars), "\(input)")
        }
        #expect(identityKey("agent:ΟΔΥΣΣΕΥΣ").unicodeScalars.elementsEqual("agent:οδυσσευς".unicodeScalars))

        // Rule 2: the writer is the member whose key is its key
        let odysseus = "agent:ΟΔΥΣΣΕΥΣ"
        let finalForm = member("agent:οδυσσευς", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem])
        let medialForm = member("agent:οδυσσευσ", "sess_b", "2026-09-01T10:14:00.000Z", [fileItem])
        #expect(refusal(quorumTB(author: odysseus, signedBy: odysseus, members: [claudeAt1013, finalForm])) == nil)
        #expect(refusal(quorumTB(author: odysseus, signedBy: odysseus, members: [claudeAt1013, medialForm]))?.contains("is not a quorum member") == true)
        #expect(refusal(quorumTB(author: "agent:οδυσσευσ", signedBy: odysseus, members: [claudeAt1013, medialForm]))?.contains("signed by its author") == true)

        // Rule 3: a commit ref compares lowercased, so abcΣ is abcς, not abcσ
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
        #expect(refusal(pair(item("commit", "abcΣ"), item("commit", "abcς")))?.contains("both cite commit") == true)
        #expect(refusal(pair(item("commit", "abcΣ"), item("commit", "abcσ"))) == nil)
    }

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

    @Test("SW-QUORUM-5: identity keys compare byte for byte, as stenographer compares code units, not by canonical equivalence")
    func keysCompareByBytes() throws {
        // NFKC keeps U+034F (CGJ) between the marks, so U+0301 doesn't compose; then CGJ, a
        // default-ignorable, is removed. The keys, agent:a + U+0316 U+0301 and agent:á + U+0316,
        // are canonically equivalent (Swift's String == says equal) but differ code unit for code unit
        let x = "agent:a\u{0316}\u{034F}\u{0301}"
        let y = "agent:\u{00E1}\u{0316}"
        #expect(Array(identityKey(x).unicodeScalars) == ["a", "g", "e", "n", "t", ":", "a", "\u{0316}", "\u{0301}"])
        #expect(Array(identityKey(y).unicodeScalars) == ["a", "g", "e", "n", "t", ":", "\u{00E1}", "\u{0316}"])
        #expect(identityKey(x) == identityKey(y), "canonical equivalence: what the reader must not compare by")

        // Rule 2: the writer is a member, and signs its TB, by key (stenographer's checkQuorum refuses both)
        let memberY = member(y, "sess_b", "2026-09-01T10:14:00.000Z", [fileItem])
        #expect(refusal(quorumTB(author: x, signedBy: x, members: [claudeAt1013, memberY]))?.contains("is not a quorum member") == true)
        #expect(refusal(quorumTB(author: y, signedBy: x, members: [claudeAt1013, memberY]))?.contains("signed by its author") == true)
        #expect(refusal(quorumTB(author: y, signedBy: "AGENT:\u{00C1}\u{0316}", members: [claudeAt1013, memberY])) == nil)

        // A draft's author and its notary are two people unless their keys are one
        let draft = TombstoneDraft(claim: "searchV1 is gone.", evidence: [TruthEvidence(kind: .commit, ref: "c4fe0b1")], signer: y)
        #expect(try draft.proposal(author: x).author == x)
        #expect(throws: TruthError.self) { try draft.proposal(author: "AGENT:\u{00C1}\u{0316}") }

        // The signer registry looks names up by key, byte for byte, as stenographer's Map does
        let registry = try TruthSignerRegistry(signers: [TruthSigner(id: y, role: .agent)])
        #expect(registry.lookup("Agent:\u{00C1}\u{0316}")?.role == .agent)
        #expect(registry.lookup(x) == nil)
        let both = try TruthSignerRegistry(signers: [TruthSigner(id: x, role: .human), TruthSigner(id: y, role: .agent)])
        #expect(both.lookup(x)?.role == .human)
        #expect(both.lookup(y)?.role == .agent)
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
