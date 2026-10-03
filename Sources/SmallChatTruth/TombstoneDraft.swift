import Foundation

// MARK: - Authoring a tombstone
//
// A human who already knows a value is dead asserts it: a TB with evidence
// and the literals an objection can cite. One writer per wiki file: a tool
// that authors truth outside stenographer never appends to a file
// stenographer exports (a full export would drop the line, and the file
// would no longer be one writer's stream). The draft goes to stenographer
// as a PROPOSAL envelope (`POST /proposals`), and the person notarizes it
// there (`POST /proposals/:id/notarize`), which mints the TB under their
// name. SmallChatAgents' NotaryClient sends both requests.

public struct TombstoneDraft: Sendable, Equatable {
    public var claim: String
    public var evidence: [TruthEvidence]
    public var literals: [TruthTombstonedLiteral]
    /// Who asserts it (the notary). Must be a specific person, not "system"/"assistant".
    public var signer: String

    public init(claim: String = "", evidence: [TruthEvidence] = [], literals: [TruthTombstonedLiteral] = [], signer: String = "") {
        self.claim = claim
        self.evidence = evidence
        self.literals = literals
        self.signer = signer
    }

    /// Problems that block signing, in the order a form should show them.
    public func problems() -> [String] {
        var out: [String] = []
        if claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Say what is dead and what replaces it.")
        }
        if evidence.isEmpty {
            out.append("Add at least one piece of evidence.")
        }
        for (i, e) in evidence.enumerated() where e.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Evidence \(i + 1) needs a reference.")
        }
        for (i, literal) in literals.enumerated() {
            if let reason = literal.validationError() { out.append("Literal \(i + 1): \(reason).") }
        }
        let who = signer.trimmingCharacters(in: .whitespacesAndNewlines)
        if who.isEmpty {
            out.append("Sign it: set who you sign as.")
        } else if isAnonymousIdentity(who) {
            out.append("“\(who)” isn't an accountable identity — sign as a person.")
        } else if let issue = identityIssue(who) {
            out.append("“\(who)” can't sign: \(issue).")
        }
        return out
    }

    /// The signer, trimmed.
    public var notary: String {
        signer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The draft as a suite PROPOSAL envelope (`kind: "tb"`), drafted by
    /// `author` for the signer to notarize — values trimmed, blank details
    /// dropped. `author` must not be the signer: stenographer refuses a
    /// notary who already stands behind the proposal (contempt of corpus).
    /// Throws the first problem if the draft isn't ready.
    public func proposal(
        author: String,
        source: String = "agent",
        id: String = ulid(),
        now: Date = Date()
    ) throws -> TruthProposalEnvelope {
        if let first = problems().first { throw TruthError.malformedLine(line: 0, reason: first) }
        if sameIdentity(author, notary) {
            throw TruthError.malformedLine(line: 0, reason: "“\(notary)” can't both draft and notarize the tombstone — sign as a person")
        }
        func clean(_ s: String?) -> String? {
            s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return try TruthProposalEnvelope(
            id: id,
            ts: truthTimestamp(now),
            author: author,
            draft: .tb(
                claim: claim.trimmingCharacters(in: .whitespacesAndNewlines),
                evidence: evidence.map {
                    TruthEvidence(kind: $0.kind, ref: $0.ref.trimmingCharacters(in: .whitespacesAndNewlines), detail: clean($0.detail))
                },
                literals: literals.map {
                    TruthTombstonedLiteral(dead: ecmaScriptTrim($0.dead), subject: clean($0.subject).map(ecmaScriptTrim), current: clean($0.current).map(ecmaScriptTrim))
                }
            ),
            signal: TruthProposalEnvelope.Signal(source: source, detail: "drafted in the smallchat messenger for \(notary) to notarize")
        )
    }
}
