import Foundation

// MARK: - SmallChatTruth
//
// Consumer-side seam for stenographer's TB/UV v2 asserted-truth ledger,
// ported from the TS truth-ledger interop in `@shorthand/core/truth`.
// Short-hand-style compaction reads signed TB/UV entries from the
// append-only wiki JSONL, carries them under the §7 consumption rules,
// and may emit candidate invariants back as PROPOSAL lines — never as
// signed truth.
//
// The design principle that must survive any refactor: TWO AXES, NOT
// ONE. Every entry carries provenance (where did this come from) and a
// confidence type (how much should you trust it). Collapsing TB and UV
// back into one "invariant" bucket is a regression.

// MARK: - Confidence & statuses

/// The confidence axis: TB (asserted, evidence-backed) vs UV (unverified).
public enum TruthConfidence: String, Sendable, Codable {
    case tb
    case uv
}

public enum TbStatus: String, Sendable, Codable {
    case active
    case contested
    case overridden
}

public enum UvStatus: String, Sendable, Codable {
    case open
    case verified
    case refuted
}

// MARK: - Evidence & verification hints

/// A piece of evidence attached to a TB.
public struct TruthEvidence: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case commit, file, test, command, wiki, message
    }

    public let kind: Kind
    /// Commit sha, file/line, test name, command line, wiki entry id, or message id.
    public let ref: String
    /// What the evidence shows (e.g. captured command output).
    public let detail: String?

    public init(kind: Kind, ref: String, detail: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.detail = detail
    }
}

/// Machine-actionable verification hint carried by every UV.
public struct TruthVerifyBy: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case command, inspect, ask, observe
    }

    public let kind: Kind
    /// The command to run, file/symbol to read, person to ask, or condition to observe.
    public let value: String
    /// For `inspect`: what to look for.
    public let detail: String?

    public init(kind: Kind, value: String, detail: String? = nil) {
        self.kind = kind
        self.value = value
        self.detail = detail
    }
}

/// A dead literal a tombstone declares (§12) — what a real-time objection
/// can cite. `subject` names the identifier a bare value belongs to;
/// `current` is the replacement, if any.
public struct TruthTombstonedLiteral: Sendable, Codable, Equatable {
    public let dead: String
    public let subject: String?
    public let current: String?

    public init(dead: String, subject: String? = nil, current: String? = nil) {
        self.dead = dead
        self.subject = subject
        self.current = current
    }
}

// MARK: - Entries

/// A signed, evidence-backed tombstone: ground truth once active.
public struct TruthTbEntry: Sendable, Equatable {
    public let id: String
    /// ISO timestamp the entry was asserted.
    public let ts: String
    public let author: String
    /// What is dead and what replaces it (if anything).
    public let claim: String
    public let evidence: [TruthEvidence]
    /// The asserting author (distinct from `author` when an agent drafted and a human signed).
    public let signedBy: String?
    public var status: TbStatus
    /// Matchable dead literals (§12). Empty when the TB declares none.
    public let literals: [TruthTombstonedLiteral]
    /// Opaque stenographer namespace (`x-steno`), preserved for round-tripping.
    public let xSteno: JSONValue?

    public init(
        id: String,
        ts: String,
        author: String,
        claim: String,
        evidence: [TruthEvidence],
        signedBy: String?,
        status: TbStatus,
        literals: [TruthTombstonedLiteral] = [],
        xSteno: JSONValue? = nil
    ) {
        self.id = id
        self.ts = ts
        self.author = author
        self.claim = claim
        self.evidence = evidence
        self.signedBy = signedBy
        self.status = status
        self.literals = literals
        self.xSteno = xSteno
    }
}

/// An unverified assertion: believed true, stated before verification exists.
public struct TruthUvEntry: Sendable, Equatable {
    public let id: String
    public let ts: String
    public let author: String
    /// The belief, in full sentences.
    public let assertion: String
    /// Why the author believes it.
    public let basis: String
    public let verifyBy: TruthVerifyBy
    /// Id of a TB this UV disputes — puts that TB into `contested`.
    public let contests: String?
    public var status: UvStatus
    public let xSteno: JSONValue?

    public init(
        id: String,
        ts: String,
        author: String,
        assertion: String,
        basis: String,
        verifyBy: TruthVerifyBy,
        contests: String?,
        status: UvStatus,
        xSteno: JSONValue? = nil
    ) {
        self.id = id
        self.ts = ts
        self.author = author
        self.assertion = assertion
        self.basis = basis
        self.verifyBy = verifyBy
        self.contests = contests
        self.status = status
        self.xSteno = xSteno
    }
}

public enum TruthLedgerEntry: Sendable, Equatable {
    case tb(TruthTbEntry)
    case uv(TruthUvEntry)

    public var id: String {
        switch self {
        case .tb(let entry): return entry.id
        case .uv(let entry): return entry.id
        }
    }
}

// MARK: - Consumption rules (§7)

/// How a consumer (compaction included) must treat an entry.
public enum ConsumptionAction: Sendable, Equatable {
    /// Active TB — ground truth. Compact it, rely on it, cite it.
    case groundTruth
    /// Contested TB — ground truth with a visible asterisk: carry the TB and its contesting UVs.
    case contested
    /// Open UV — flag, don't block. Never let it read as proven.
    case flag
    /// Refuted UV / overridden TB / verified UV — history, never citable.
    case history
}

/// Shipped verbatim from stenographer so consumers inherit identical rules.
public let consumptionRules = """
Consumption rules by confidence type:
- Active TB: treat as ground truth. A reviewer may block on it; a code agent may rely on it.
- Contested TB: ground truth with a visible asterisk — cite both the TB and the contesting UV.
- Open UV: FLAG, DON'T BLOCK. A finding grounded only in a UV is phrased as a question or heads-up, never a demanded change. If your current task would settle the UV cheaply, do so via resolve_uv.
- Refuted UV / overridden TB: retrievable for history, excluded from current-truth by default, never citable as support for a claim.
"""

/// Current truth partitioned by consumption action.
public struct TruthSelection: Sendable, Equatable {
    /// Active TBs — ground truth.
    public let groundTruth: [TruthTbEntry]
    /// Contested TBs paired with their live contesting UVs — carry both.
    public let contested: [(tombstone: TruthTbEntry, contestedBy: [TruthUvEntry])]
    /// Open UVs — flagged, never presented as proven.
    public let unverified: [TruthUvEntry]
    /// Overridden TBs, refuted/verified UVs — excluded from current truth.
    public let history: [TruthLedgerEntry]

    public init(
        groundTruth: [TruthTbEntry],
        contested: [(tombstone: TruthTbEntry, contestedBy: [TruthUvEntry])],
        unverified: [TruthUvEntry],
        history: [TruthLedgerEntry]
    ) {
        self.groundTruth = groundTruth
        self.contested = contested
        self.unverified = unverified
        self.history = history
    }

    public static func == (lhs: TruthSelection, rhs: TruthSelection) -> Bool {
        lhs.groundTruth == rhs.groundTruth
            && lhs.contested.count == rhs.contested.count
            && zip(lhs.contested, rhs.contested).allSatisfy {
                $0.tombstone == $1.tombstone && $0.contestedBy == $1.contestedBy
            }
            && lhs.unverified == rhs.unverified
            && lhs.history == rhs.history
    }
}

// MARK: - Authorship — no anonymous write path

public enum TruthError: Error, Equatable, CustomStringConvertible {
    case anonymousAuthor(String)
    case malformedLine(line: Int, reason: String)

    public var description: String {
        switch self {
        case .anonymousAuthor(let identity):
            return "anonymous or generic identities cannot write toward the truth ledger "
                + "(got \"\(identity)\") — use a registered human handle or agent identity"
        case .malformedLine(let line, let reason):
            return "malformed ledger line \(line): \(reason)"
        }
    }
}

/// Identities that cannot stand behind anything — mirrors stenographer's floor.
private let anonymousIdentities: Set<String> = [
    "", "system", "assistant", "agent", "ai", "bot", "anonymous",
    "unknown", "user", "human", "admin", "null", "none", "me",
]

public func isAnonymousIdentity(_ identity: String) -> Bool {
    anonymousIdentities.contains(
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
}

/// Throws unless `author` is a specific, accountable identity.
public func assertAccountableAuthor(_ author: String) throws {
    if isAnonymousIdentity(author) {
        throw TruthError.anonymousAuthor(author)
    }
}

// MARK: - ULID (Crockford base32, time-prefixed)

private let base32 = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// Generates a 26-character ULID. Monotonicity within a millisecond is the
/// caller's concern here (proposal emission salts with distinct targets).
public func ulid(now: Date = Date()) -> String {
    var t = UInt64(now.timeIntervalSince1970 * 1000)
    var time = [Character](repeating: "0", count: 10)
    for i in stride(from: 9, through: 0, by: -1) {
        time[i] = base32[Int(t % 32)]
        t /= 32
    }
    let rand = (0..<16).map { _ in base32[Int.random(in: 0..<32)] }
    return String(time) + String(rand)
}
