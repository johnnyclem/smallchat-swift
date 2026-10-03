import Foundation
import SmallChatCore

// MARK: - The agent quorum (truth format v2, "Agent quorum")
//
// Agents settle claims only together: two or more agent sessions agreeing
// from different angles at the same time. An agent on its own can only
// attest. A settlement by agents (an ADDENDUM verifying or refuting a UV,
// or a TB an agent signs) is valid only when its line carries a `quorum`:
// one member per agreeing session, each with the evidence it brought.
//
// A reader refuses a line whose quorum breaks the rules (spec numbering):
//   1. Two or more members, from distinct agent sessions (compared trimmed
//      of White_Space), each an accountable identity.
//   2. The writer is a member (by key), and a TB is signed by its writer.
//   3. From different angles: every member cites settling evidence, no item
//      appears in two members (refs compared normalized for their kind), and
//      the settling evidence spans two kinds or more. A kind this version
//      doesn't know may be a newer writer's settling kind: it never makes a
//      line break these clauses. It is an unknown value, which admission
//      fails closed on instead (`TruthWiki`).
//   4. At the same time: the members' and the line's timestamps lie within
//      15 minutes of each other, read to the millisecond.
//   5. Agreeing: an ADDENDUM's verdicts agree, with each other and with each
//      `verifies` or `refutes` link it lists, and it never overrides; a TB
//      carries the literals its members agreed on. (That they drafted those
//      literals is the writer's obligation: no reader sees the drafts.)
//   6. The line shows its evidence: every member's items, and no others,
//      compared by kind and trimmed ref.
// The rules are line-local, like the link rules. Who is an agent is not:
// TruthWiki's admission asks the signer registry, or the `agent:` prefix
// without one. The reference is stenographer's src/truth/quorum.ts.

/// One agent session that agreed: who, which session, when, and the evidence it brought.
public struct TruthQuorumMember: Sendable, Equatable {
    /// What an ADDENDUM member's session filed.
    public enum Verdict: String, Sendable, Equatable {
        case verified, refuted
    }

    public let author: String
    public let agentSessionId: String
    public let ts: String
    public let evidence: [TruthEvidence]
    /// An ADDENDUM member's verdict; nil on a TB's members.
    public let verdict: Verdict?

    public init(author: String, agentSessionId: String, ts: String, evidence: [TruthEvidence], verdict: Verdict? = nil) {
        self.author = author
        self.agentSessionId = agentSessionId
        self.ts = ts
        self.evidence = evidence
        self.verdict = verdict
    }
}

public enum TruthQuorum {
    /// Members' and the line's timestamps lie within this of each other: 15 minutes.
    public static let windowMilliseconds = 900_000
    /// The fewest agent sessions that settle a claim together.
    public static let minimumMembers = 2
    /// Without a signer registry, an agent is an identity whose key starts with this.
    public static let agentPrefix = "agent:"

    // MARK: Who is an agent

    /// Whether `identity` is an agent's: the role a signer registry lists, and
    /// for an identity it doesn't list, or without one, the `agent:` prefix
    /// (stenographer's classifier). An agent's TB needs a quorum.
    public static func isAgent(_ identity: String, signers: TruthSignerRegistry?) -> Bool {
        if let listed = signers?.lookup(identity) { return listed.role == .agent }
        return hasCodeUnitPrefix(identityKey(identity), agentPrefix)
    }

    /// Whether `identity` may be a quorum member: with a signer registry, one
    /// it lists with role `agent` (an unlisted `agent:` name is no witness);
    /// without one, the `agent:` prefix.
    static func isMemberAgent(_ identity: String, signers: TruthSignerRegistry?) -> Bool {
        if let signers { return signers.lookup(identity)?.role == .agent }
        return isAgent(identity, signers: nil)
    }

    // MARK: The rules

    /// The rules a line carrying a `quorum` breaks, each as one message
    /// naming its rule; empty when it keeps them all, or carries no quorum.
    /// Line-local: it reads nothing but `line`, and the links the line lists
    /// in `x-steno.links`.
    public static func issues(in line: [String: AnyCodableValue]) -> [String] {
        guard let raw = line["quorum"] else { return [] }
        let type = string(line["type"])
        guard type == "TB" || type == "ADDENDUM" else {
            return ["a quorum appears only on TB and ADDENDUM lines, not on a \(type ?? jsonText(line["type"] ?? .null)) line"]
        }
        guard case .array(let list) = raw else { return ["a quorum is an array of members"] }

        // The members' shape, before any rule can be read
        var shape: [String] = []
        var members: [Member] = []
        for (i, value) in list.enumerated() {
            let n = i + 1
            guard case .dict(let m) = value else {
                shape.append("quorum member \(n) is not an object")
                continue
            }
            let author = string(m["author"])
            let session = string(m["agentSessionId"])
            let ts = string(m["ts"])
            let evidence = evidenceItems(m["evidence"])
            let verdict = string(m["verdict"]).flatMap(TruthQuorumMember.Verdict.init(rawValue:))
            if author == nil { shape.append("quorum member \(n) has no author") }
            if session == nil { shape.append("quorum member \(n) has no agent session (rule 1)") }
            if !(ts.map(TruthFormat.isRFC3339DateTime) ?? false) { shape.append("quorum member \(n)'s ts is not an RFC 3339 date-time") }
            if (evidence?.isEmpty ?? true) { shape.append("quorum member \(n) cites no evidence") }
            if type == "ADDENDUM", verdict == nil { shape.append("quorum member \(n)'s verdict is verified or refuted") }
            if let author, let session, let ts, let evidence {
                members.append(Member(author: author, session: session, ts: ts, evidence: evidence, verdict: verdict))
            }
        }
        if !shape.isEmpty { return shape }
        var issues: [String] = []

        // Rule 1: two or more, distinct sessions, accountable identities
        if members.count < minimumMembers {
            issues.append("a quorum needs at least \(minimumMembers) members, and this one has \(members.count) (rule 1)")
        }
        var sessions: [[UInt8]: Int] = [:]
        for (i, m) in members.enumerated() {
            let session = trimWhiteSpace(m.session)
            if session.isEmpty {
                issues.append("quorum member \(i + 1) names no agent session (rule 1)")
            } else if let prior = sessions[Array(session.utf8)] {
                issues.append("quorum members \(prior) and \(i + 1) share agent session \(session): one session is one witness (rule 1)")
            } else {
                sessions[Array(session.utf8)] = i + 1
            }
            if let who = memberIdentityIssue(m.author) { issues.append("quorum member \(i + 1): \(who) (rule 1)") }
        }

        // Rule 2: the writer is a member; a TB is signed by its writer
        let author = string(line["author"]) ?? ""
        if !members.contains(where: { identityKey($0.author) == identityKey(author) }) {
            issues.append("the line's author \(author) is not a quorum member: the agent whose attestation completed the quorum writes it (rule 2)")
        }
        if type == "TB" {
            let signedBy = string(line["signedBy"])
            if signedBy.map({ identityKey($0) != identityKey(author) }) ?? true {
                issues.append("a quorum TB is signed by its author (rule 2): signedBy \(signedBy ?? "null") is not \(author)")
            }
        }

        // Rule 3: from different angles. A kind this version doesn't know may be
        // a newer writer's settling kind: an unknown value, which never refuses a line
        var settlingKinds: [String] = []
        let unknownKinds = members.contains { $0.evidence.contains { !TruthEvidence.Kind(rawValue: $0.kind).isKnown } }
        for (i, m) in members.enumerated() {
            let settling = m.evidence.filter { TruthEvidence.Kind(rawValue: $0.kind).evidenceClass == .settling }
            if settling.isEmpty, m.evidence.allSatisfy({ TruthEvidence.Kind(rawValue: $0.kind).isKnown }) {
                let kinds = TruthEvidence.Kind.settling.map(\.rawValue).joined(separator: ", ")
                issues.append("quorum member \(i + 1) cites no settling evidence (\(kinds)) (rule 3)")
            }
            for e in settling where !settlingKinds.contains(e.kind) { settlingKinds.append(e.kind) }
        }
        for i in members.indices {
            for j in 0..<i {
                if let shared = members[i].evidence.first(where: { e in members[j].evidence.contains { sameEvidence(e, $0) } }) {
                    issues.append("quorum members \(j + 1) and \(i + 1) both cite \(describe(shared)): each member brings evidence of its own (rule 3)")
                    break
                }
            }
        }
        if settlingKinds.count == 1, !unknownKinds {
            issues.append("a quorum's settling evidence spans at least two settling kinds, and this one cites only \(settlingKinds[0]) (rule 3)")
        }

        // Rule 4: at the same time, to the millisecond
        let times = (members.map(\.ts) + [string(line["ts"]) ?? ""]).map(TruthFormat.epochMilliseconds)
        if times.contains(where: { $0 == nil }) {
            issues.append("the line's ts is not a timestamp (rule 4)")
        } else {
            let known = times.compactMap { $0 }
            let span = known.max()! - known.min()!
            if span > Int64(windowMilliseconds) {
                issues.append("the quorum's members and its line lie more than 15 minutes apart (\(span) ms) (rule 4)")
            }
        }

        // Rule 5: agreeing. An ADDENDUM's verdicts agree, with each other and with
        // the links it lists (one that lists no resolution link, or only types
        // this version doesn't know, is checked for agreeing verdicts only); a TB
        // carries the literals its members agreed on
        if type == "TB" {
            var literals: [AnyCodableValue] = []
            if case .array(let list)? = line["literals"] { literals = list }
            if literals.isEmpty {
                issues.append("a quorum TB carries the literals its members agreed on (literals, at least one) (rule 5)")
            }
        }
        if type == "ADDENDUM" {
            var verdicts: [String] = []
            for m in members { if let v = m.verdict?.rawValue, !verdicts.contains(v) { verdicts.append(v) } }
            if verdicts.count > 1 { issues.append("the quorum's members disagree: \(verdicts.joined(separator: " and ")) (rule 5)") }
            if let links = linkTypes(line) {
                if links.contains("overrides") {
                    issues.append("a quorum ADDENDUM never overrides a TB: overriding is a person's act (rule 5)")
                }
                for link in links {
                    let applied: TruthQuorumMember.Verdict
                    switch link {
                    case "verifies": applied = .verified
                    case "refutes": applied = .refuted
                    default: continue
                    }
                    for (i, m) in members.enumerated() where m.verdict != applied {
                        issues.append("quorum member \(i + 1)'s verdict \(m.verdict?.rawValue ?? "none") is not the one its line's \(link) link applies (\(applied.rawValue)) (rule 5)")
                    }
                }
            }
        }
        return issues + ruleSix(line, members)
    }

    /// Rule 6: the line's evidence is the members' evidence (items compare by kind and trimmed ref).
    private static func ruleSix(_ line: [String: AnyCodableValue], _ members: [Member]) -> [String] {
        guard let shown = evidenceItems(line["evidence"]) else { return ["the line's evidence is not an evidence list (rule 6)"] }
        var issues: [String] = []
        let cited = Set(members.flatMap { $0.evidence.map(evidenceKey) })
        let shownKeys = Set(shown.map(evidenceKey))
        for (i, m) in members.enumerated() {
            for e in m.evidence where !shownKeys.contains(evidenceKey(e)) {
                issues.append("the line's evidence lacks quorum member \(i + 1)'s \(describe(e)) (rule 6)")
            }
        }
        for e in shown where !cited.contains(evidenceKey(e)) {
            issues.append("the line's evidence holds \(describe(e)), which no quorum member cites (rule 6)")
        }
        return issues
    }

    /// Why a quorum's members don't settle a claim for this reader, when
    /// rule 3 holds only by a kind it doesn't know: read as question-class
    /// (fail closed), every member must still cite settling evidence and the
    /// members two settling kinds. Nil when they do.
    static func knownAnglesIssue(_ members: [TruthQuorumMember]) -> String? {
        let unknown = members.flatMap { $0.evidence.map(\.kind) }.filter { !$0.isKnown }.map(\.rawValue)
        var seen: [String] = []
        for kind in unknown where !seen.contains(kind) { seen.append(kind) }
        let note = seen.isEmpty ? "" : " (\(seen.map { "'\($0)'" }.joined(separator: ", ")) is evidence this reader doesn't know, which settles nothing)"
        var kinds: [String] = []
        for (i, m) in members.enumerated() {
            let settling = m.evidence.filter(\.isSettling)
            if settling.isEmpty { return "quorum member \(i + 1) cites no settling evidence this reader knows\(note)" }
            for e in settling where !kinds.contains(e.kind.rawValue) { kinds.append(e.kind.rawValue) }
        }
        if kinds.count < 2 { return "its members' settling evidence spans one kind this reader knows (\(kinds.joined()))\(note)" }
        return nil
    }

    // MARK: Comparing evidence

    /// One evidence item as the rules read it.
    struct Item {
        let kind: String
        let ref: String
    }

    struct Member {
        let author: String
        let session: String
        let ts: String
        let evidence: [Item]
        let verdict: TruthQuorumMember.Verdict?
    }

    /// An item as rule 6 compares it: its kind and its ref, trimmed, code unit for code unit.
    private struct ItemKey: Hashable {
        let kind: [UInt8]
        let ref: [UInt8]
    }

    private static func evidenceKey(_ item: Item) -> ItemKey {
        ItemKey(kind: Array(item.kind.utf8), ref: Array(trimWhiteSpace(item.ref).utf8))
    }

    private static func describe(_ item: Item) -> String {
        "\(item.kind) \(trimWhiteSpace(item.ref))"
    }

    /// The characters with the Unicode White_Space property, which the spec
    /// lists: what every codec trims from a member's session and a ref. (Not
    /// U+FEFF, which ECMAScript's `trim` removes too.)
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `value` without leading and trailing White_Space (`isWhiteSpace`).
    static func trimWhiteSpace(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhiteSpace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhiteSpace($0) })!
        return String(scalars[first...last])
    }

    /// A ref as rule 3 compares it, normalized for its kind so that one piece
    /// of evidence spelled two ways is one item: a `commit` lowercased (as
    /// ECMAScript lowercases: `ecmaScriptLowercased`); a `file` path with `\`
    /// read as `/` and empty and `.` segments dropped (`./src//x.ts` is
    /// `src/x.ts`; a leading `/` stays); a `test` or `claimed-command` with
    /// each run of White_Space read as one space. Every ref is trimmed first.
    static func evidenceRefKey(kind: String, ref: String) -> String {
        let ref = trimWhiteSpace(ref)
        switch kind {
        case "commit":
            return ecmaScriptLowercased(ref)
        case "file":
            var segments: [String.UnicodeScalarView] = [String.UnicodeScalarView()]
            for scalar in ref.unicodeScalars {
                if scalar == "/" || scalar == "\\" {
                    segments.append(String.UnicodeScalarView())
                } else {
                    segments[segments.count - 1].append(scalar)
                }
            }
            let absolute = segments[0].isEmpty
            let kept = segments.filter { !$0.isEmpty && !($0.count == 1 && $0.first == ".") }
            return (absolute ? "/" : "") + kept.map { String($0) }.joined(separator: "/")
        case "test", "claimed-command":
            var out = String.UnicodeScalarView()
            var inRun = false
            for scalar in ref.unicodeScalars {
                if isWhiteSpace(scalar) {
                    if !inRun { out.append(" ") }
                    inRun = true
                } else {
                    out.append(scalar)
                    inRun = false
                }
            }
            return String(out)
        default:
            return ref
        }
    }

    /// Whether two items are the same evidence (rule 3): the same kind, and
    /// refs equal once normalized for it (`evidenceRefKey`), where a `commit`
    /// one that starts with the other also counts (an abbreviated hash).
    /// Compared code unit for code unit, as stenographer compares them.
    static func sameEvidence(_ a: Item, _ b: Item) -> Bool {
        guard a.kind.utf8.elementsEqual(b.kind.utf8) else { return false }
        let x = Array(evidenceRefKey(kind: a.kind, ref: a.ref).utf8)
        let y = Array(evidenceRefKey(kind: b.kind, ref: b.ref).utf8)
        if x == y { return true }
        return a.kind == "commit" && !x.isEmpty && !y.isEmpty && (x.starts(with: y) || y.starts(with: x))
    }

    // MARK: Reading the line

    private static func string(_ value: AnyCodableValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// An evidence list's items, or nil when the value isn't a list of
    /// `{kind, ref, detail?}` with non-empty strings (the codec's evidence rule).
    private static func evidenceItems(_ value: AnyCodableValue?) -> [Item]? {
        guard case .array(let list)? = value else { return nil }
        var items: [Item] = []
        for value in list {
            guard case .dict(let e) = value, let kind = string(e["kind"]), !kind.isEmpty, let ref = string(e["ref"]), !ref.isEmpty else { return nil }
            switch e["detail"] {
            case nil, .string?: break
            default: return nil
            }
            items.append(Item(kind: kind, ref: ref))
        }
        return items
    }

    /// The types of the links the line lists from itself in `x-steno.links`,
    /// or nil when it lists none there (no `x-steno`, or no `links` array).
    private static func linkTypes(_ line: [String: AnyCodableValue]) -> [String]? {
        guard case .dict(let x)? = line["x-steno"], case .array(let links)? = x["links"] else { return nil }
        let id = string(line["id"])
        return links.compactMap { value in
            guard case .dict(let l) = value, string(l["fromId"]) == id else { return nil }
            return string(l["type"])
        }
    }

    /// The identity rules for a quorum member: never anonymous, generic,
    /// reserved or with control characters (stenographer's messages).
    private static func memberIdentityIssue(_ identity: String) -> String? {
        if isAnonymousIdentity(identity) { return "'\(identity)' is anonymous or generic" }
        if hasControlCharacters(identity) { return "its identity contains control characters" }
        if isReservedIdentity(identity) { return "'\(identity)' is reserved ('\(truthMigrationAuthor)' and '\(truthDetectorPrefix)*')" }
        return nil
    }

    /// The members of a line's quorum, as an entry carries them (the codec checked their shape).
    static func members(_ value: AnyCodableValue?) -> [TruthQuorumMember]? {
        guard case .array(let list)? = value else { return nil }
        return list.compactMap { value -> TruthQuorumMember? in
            guard case .dict(let m) = value else { return nil }
            var evidence: [TruthEvidence] = []
            if case .array(let items)? = m["evidence"] {
                for case .dict(let e) in items {
                    evidence.append(TruthEvidence(kind: TruthEvidence.Kind(rawValue: string(e["kind"]) ?? ""), ref: string(e["ref"]) ?? "", detail: string(e["detail"])))
                }
            }
            return TruthQuorumMember(
                author: string(m["author"]) ?? "",
                agentSessionId: string(m["agentSessionId"]) ?? "",
                ts: string(m["ts"]) ?? "",
                evidence: evidence,
                verdict: string(m["verdict"]).flatMap(TruthQuorumMember.Verdict.init(rawValue:))
            )
        }
    }
}
