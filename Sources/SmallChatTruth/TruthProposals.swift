import Foundation
import SmallChatCore

// MARK: - Proposals — the only write path toward the ledger
//
// Machines detect; authors assert. This module never writes signed truth:
// it drafts PROPOSAL envelopes (truth format v2, the one envelope for the
// whole suite) that stenographer files, and nothing becomes truth until a
// named person signs it there. There is no anonymous write path — generic
// identities are rejected before an envelope is ever built, and the
// compactor cannot sign its own output.
//
//   {schemaVersion: 2, seq, id, type: "PROPOSAL", ts, author, kind: "tb"|"uv",
//    draft, targetRef, signal: {source, ...}, agentSessionId, prevHash, hash}
//
// `signal.source` is `compaction-candidate`, `agent` or `detector:<name>`.
// The bare short-hand proposal line and the `shorthand-compaction` source
// are retired: still read by stenographer, no longer written.

/// RFC 3339 UTC with milliseconds, as stenographer writes `ts`.
public func truthTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// One PROPOSAL envelope: a drafted TB or UV.
public struct TruthProposalEnvelope: Sendable, Equatable {
    public enum Draft: Sendable, Equatable {
        /// A drafted tombstone: what is dead, the evidence, and the literals an objection can cite.
        case tb(claim: String, evidence: [TruthEvidence], literals: [TruthTombstonedLiteral])
        /// A drafted unverified assertion.
        case uv(assertion: String, basis: String, verifyBy: TruthVerifyBy, contests: String?)
    }

    public struct Signal: Sendable, Equatable {
        /// `compaction-candidate`, `agent`, or `detector:<name>`.
        public let source: String
        public let detail: String?

        public init(source: String, detail: String? = nil) {
            self.source = source
            self.detail = detail
        }
    }

    /// Unique per envelope: stenographer files an envelope once by its id.
    public let id: String
    public let ts: String
    /// Who drafted it: a person, an agent identity or a `detector:<name>`.
    public let author: String
    public let draft: Draft
    /// What the proposal is about (a dedupe key), or nil.
    public let targetRef: String?
    public let signal: Signal
    public let agentSessionId: String?

    /// `tb` or `uv`.
    public var kind: String {
        if case .tb = draft { return "tb" }
        return "uv"
    }

    /// Validates the envelope as stenographer's intake reads it. Throws
    /// `TruthError` for an anonymous or reserved author (`detector:*` may
    /// draft), or a draft stenographer would refuse.
    public init(
        id: String = ulid(),
        ts: String = truthTimestamp(Date()),
        author: String,
        draft: Draft,
        targetRef: String? = nil,
        signal: Signal,
        agentSessionId: String? = nil
    ) throws {
        try assertAccountableAuthor(author, allowDetector: true)
        func refuse(_ reason: String) -> TruthError { .malformedLine(line: 0, reason: reason) }
        guard TruthFormat.isId(id) else { throw refuse("a proposal id is 1–256 characters: letters, digits, . _ : -") }
        guard TruthFormat.isRFC3339DateTime(ts) else { throw refuse("ts must be an RFC 3339 date-time") }
        guard !signal.source.isEmpty else { throw refuse("signal.source can't be empty") }
        switch draft {
        case .tb(let claim, let evidence, let literals):
            guard !claim.isEmpty else { throw refuse("a TB draft needs a claim") }
            guard !evidence.isEmpty else { throw refuse("a TB draft needs at least one piece of evidence") }
            for e in evidence where e.kind.rawValue.isEmpty || e.ref.isEmpty {
                throw refuse("every piece of evidence needs a kind and a reference")
            }
            for (i, literal) in literals.enumerated() {
                if let issue = TruthFormat.literalIssue(Self.literalValue(literal), version: 2) {
                    throw refuse("literal \(i + 1): \(issue)")
                }
            }
        case .uv(let assertion, let basis, let verifyBy, let contests):
            guard !assertion.isEmpty, !basis.isEmpty else { throw refuse("a UV draft needs an assertion and a basis") }
            guard !verifyBy.kind.rawValue.isEmpty, !verifyBy.value.isEmpty else { throw refuse("a UV draft needs verifyBy kind and value") }
            if let contests, !TruthFormat.isId(contests) { throw refuse("contests must be an entry id") }
        }
        self.id = id
        self.ts = ts
        self.author = author
        self.draft = draft
        self.targetRef = targetRef
        self.signal = signal
        self.agentSessionId = agentSessionId
    }

    private static func literalValue(_ l: TruthTombstonedLiteral) -> AnyCodableValue {
        var object: [String: AnyCodableValue] = ["dead": .string(l.dead)]
        if let subject = l.subject { object["subject"] = .string(subject) }
        if let current = l.current { object["current"] = .string(current) }
        return .dict(object)
    }

    /// The envelope's own fields in the spec's order, as a JSON object
    /// text, without the chain fields (`schemaVersion`, `seq`, `prevHash`,
    /// `hash`). `agentSessionId` is left out when there is none.
    public var body: String {
        func optional(_ s: String?) -> String { s.map(jsonQuoted) ?? "null" }
        let draftJSON: String
        switch draft {
        case .tb(let claim, let evidence, let literals):
            let items = evidence.map { e in
                jsonObject([("kind", jsonQuoted(e.kind.rawValue)), ("ref", jsonQuoted(e.ref))] + (e.detail.map { [("detail", jsonQuoted($0))] } ?? []))
            }
            var members = [("claim", jsonQuoted(claim)), ("evidence", "[" + items.joined(separator: ",") + "]")]
            if !literals.isEmpty {
                let values = literals.map { l in
                    jsonObject((l.subject.map { [("subject", jsonQuoted($0))] } ?? [])
                        + [("dead", jsonQuoted(l.dead))]
                        + (l.current.map { [("current", jsonQuoted($0))] } ?? []))
                }
                members.append(("literals", "[" + values.joined(separator: ",") + "]"))
            }
            draftJSON = jsonObject(members)
        case .uv(let assertion, let basis, let verifyBy, let contests):
            let verify = jsonObject([("kind", jsonQuoted(verifyBy.kind.rawValue)), ("value", jsonQuoted(verifyBy.value))]
                + (verifyBy.detail.map { [("detail", jsonQuoted($0))] } ?? []))
            draftJSON = jsonObject([("assertion", jsonQuoted(assertion)), ("basis", jsonQuoted(basis)), ("verifyBy", verify), ("contests", optional(contests))])
        }
        let signalJSON = jsonObject([("source", jsonQuoted(signal.source))] + (signal.detail.map { [("detail", jsonQuoted($0))] } ?? []))
        return jsonObject([
            ("id", jsonQuoted(id)), ("type", "\"PROPOSAL\""), ("ts", jsonQuoted(ts)), ("author", jsonQuoted(author)),
            ("kind", jsonQuoted(kind)), ("draft", draftJSON), ("targetRef", optional(targetRef)), ("signal", signalJSON),
        ] + (agentSessionId.map { [("agentSessionId", jsonQuoted($0))] } ?? []))
    }

    /// The envelope as a line of a proposals stream, continuing `head` (or
    /// starting a stream of its own: seq 1, prevHash null).
    public func line(after head: TruthStreamHead? = nil) throws -> String {
        try TruthFormat.chain([body], after: head)[0]
    }
}

/// A candidate invariant emitted as a machine-drafted UV proposal.
public struct InvariantProposal: Sendable, Equatable {
    public struct Draft: Sendable, Codable, Equatable {
        public let assertion: String
        public let basis: String
        public let verifyBy: TruthVerifyBy

        public init(assertion: String, basis: String, verifyBy: TruthVerifyBy) {
            self.assertion = assertion
            self.basis = basis
            self.verifyBy = verifyBy
        }
    }

    public struct Signal: Sendable, Codable, Equatable {
        public let source: String
        public let detail: String?

        public init(source: String = "compaction-candidate", detail: String? = nil) {
            self.source = source
            self.detail = detail
        }
    }

    public let type: String
    public let kind: String
    /// ULID — sortable, unique.
    public let id: String
    public let ts: String
    /// Accountable author — anonymous identities are rejected at init.
    public let author: String
    public let draft: Draft
    public let signal: Signal
    /// Dedupe key — the entity/decision this proposal targets.
    public let targetRef: String?
    /// Agent session lineage, for provenance-independence checks downstream.
    public let agentSessionId: String?
    /// The suite PROPOSAL envelope this proposal is written as.
    public let envelope: TruthProposalEnvelope

    public init(
        author: String,
        draft: Draft,
        signal: Signal = Signal(),
        targetRef: String? = nil,
        agentSessionId: String? = nil,
        now: Date = Date()
    ) throws {
        let id = ulid(now: now)
        let ts = truthTimestamp(now)
        self.envelope = try TruthProposalEnvelope(
            id: id,
            ts: ts,
            author: author,
            draft: .uv(assertion: draft.assertion, basis: draft.basis, verifyBy: draft.verifyBy, contests: nil),
            targetRef: targetRef,
            signal: TruthProposalEnvelope.Signal(source: signal.source, detail: signal.detail),
            agentSessionId: agentSessionId
        )
        self.type = "PROPOSAL"
        self.kind = "uv"
        self.id = id
        self.ts = ts
        self.author = author
        self.draft = draft
        self.signal = signal
        self.targetRef = targetRef
        self.agentSessionId = agentSessionId
    }
}

public enum TruthProposals {

    /// Serialize proposals as the lines of a proposals stream (truth format
    /// v2: hash-chained, one writer), continuing `head` — the last line of
    /// the file they will be appended to (`head(of:)`) — or starting one.
    public static func serialize(_ proposals: [InvariantProposal], after head: TruthStreamHead? = nil) -> [String] {
        (try? TruthFormat.chain(proposals.map(\.envelope.body), after: head)) ?? []
    }

    /// The last v2 line of a proposals stream, to continue it.
    public static func head(of lines: [String]) -> TruthStreamHead? {
        for raw in lines.reversed() where !ecmaScriptTrim(raw).isEmpty {
            guard case .dict(let line)? = try? parseJSON(raw),
                  let seq = line["seq"].flatMap(TruthFormat.number), case .string(let hash)? = line["hash"]
            else { return nil }
            return TruthStreamHead(seq: Int(seq), hash: hash)
        }
        return nil
    }

    /// Merge fresh proposals against lines already emitted (v2 envelopes or
    /// the retired bare lines), deduplicating by `targetRef` so repeated
    /// compaction rounds do not re-propose the same invariant. Returns the
    /// proposals that are actually new.
    public static func deduplicate(
        _ proposals: [InvariantProposal],
        againstExisting lines: [String]
    ) -> [InvariantProposal] {
        var existingRefs = Set<String>()
        for raw in lines {
            // Foreign or malformed lines never block the append path.
            if case .dict(let line)? = try? parseJSON(raw), case .string(let ref)? = line["targetRef"] {
                existingRefs.insert(ref)
            }
        }
        return proposals.filter { proposal in
            guard let ref = proposal.targetRef else { return true }
            return !existingRefs.contains(ref)
        }
    }
}
