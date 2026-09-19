import Foundation

// MARK: - Proposal emission — the only write path toward the ledger
//
// Machines detect; authors assert. This port never writes signed truth:
// it drafts `PROPOSAL(kind: "uv")` JSONL lines that stenographer ingests,
// and nothing becomes truth until a named author signs it there. There is
// no anonymous write path — generic identities are rejected before a line
// is ever emitted, and the compactor cannot sign its own output.

/// A candidate invariant emitted as a machine-drafted proposal line.
public struct InvariantProposal: Sendable, Codable, Equatable {
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

        public init(source: String = "shorthand-compaction", detail: String? = nil) {
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

    public init(
        author: String,
        draft: Draft,
        signal: Signal = Signal(),
        targetRef: String? = nil,
        agentSessionId: String? = nil,
        now: Date = Date()
    ) throws {
        try assertAccountableAuthor(author)
        self.type = "PROPOSAL"
        self.kind = "uv"
        self.id = ulid(now: now)
        self.ts = ISO8601DateFormatter().string(from: now)
        self.author = author
        self.draft = draft
        self.signal = signal
        self.targetRef = targetRef
        self.agentSessionId = agentSessionId
    }
}

public enum TruthProposals {

    /// Serialize proposals as JSONL lines.
    public static func serialize(_ proposals: [InvariantProposal]) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return proposals.compactMap { proposal in
            guard let data = try? encoder.encode(proposal) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Merge fresh proposals against lines already emitted, deduplicating
    /// by `targetRef` so repeated compaction rounds do not re-propose the
    /// same invariant. Returns the proposals that are actually new.
    public static func deduplicate(
        _ proposals: [InvariantProposal],
        againstExisting lines: [String]
    ) -> [InvariantProposal] {
        let decoder = JSONDecoder()
        var existingRefs = Set<String>()
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Foreign or malformed lines never block the append path.
            if let parsed = try? decoder.decode(InvariantProposal.self, from: Data(trimmed.utf8)),
               let ref = parsed.targetRef {
                existingRefs.insert(ref)
            }
        }
        return proposals.filter { proposal in
            guard let ref = proposal.targetRef else { return true }
            return !existingRefs.contains(ref)
        }
    }
}
