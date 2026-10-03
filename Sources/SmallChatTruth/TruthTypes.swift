import Foundation

// MARK: - SmallChatTruth
//
// Consumer-side seam for stenographer's asserted-truth ledger, reading the
// suite's truth format v2 (stenographer spec/truth-format; README in
// Tests/Fixtures/truth-format). Short-hand-style compaction reads TB/UV
// entries from a truth stream, carries them under the §7 consumption rules,
// and may emit candidate invariants back as PROPOSAL lines — never as
// signed truth. Truth itself is written by stenographer (one writer per
// wiki file); this module only reads it.
//
// The design principle that must survive any refactor: TWO AXES, NOT
// ONE. Every entry carries provenance (where did this come from) and a
// confidence type (how much should you trust it). Collapsing TB and UV
// back into one "invariant" bucket is a regression.
//
// Status, evidence kind and verifyBy kind are open strings: a newer writer
// may send values this version doesn't know. They are kept as written,
// never coerced to a known value, and an unknown or missing status is
// never current truth (fail closed). Every evidence kind has a class
// (`TruthEvidenceClass`): settling evidence points at something a reader can
// check; question evidence, and any kind this version doesn't know, can
// prompt a check but isn't one. In 1.0 the classes bind agents only: an
// agent settles a claim only in a quorum of sessions citing settling
// evidence (`TruthQuorum`), while a person may sign on any evidence.

// MARK: - Confidence & statuses

/// The confidence axis: TB (asserted, evidence-backed) vs UV (unverified).
public enum TruthConfidence: String, Sendable, Codable {
    case tb
    case uv
}

/// A TB's status. Open: any string a line carries is kept; only `active`
/// and `contested` are current truth.
public struct TbStatus: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let active: TbStatus = "active"
    public static let contested: TbStatus = "contested"
    public static let overridden: TbStatus = "overridden"
    public static let struck: TbStatus = "struck"

    /// The statuses this version knows, in lattice order.
    public static let known: [TbStatus] = [.active, .contested, .overridden, .struck]

    public var isKnown: Bool { Self.known.contains(self) }
    public var description: String { rawValue }
}

/// A UV's status. Open: any string a line carries is kept; only `open` is
/// current (a heads-up).
public struct UvStatus: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let open: UvStatus = "open"
    public static let verified: UvStatus = "verified"
    public static let refuted: UvStatus = "refuted"
    public static let struck: UvStatus = "struck"

    /// The statuses this version knows, in lattice order.
    public static let known: [UvStatus] = [.open, .verified, .refuted, .struck]

    public var isKnown: Bool { Self.known.contains(self) }
    public var description: String { rawValue }
}

// MARK: - Evidence & verification hints

/// What an evidence kind can do (truth format v2, "Evidence classes").
public enum TruthEvidenceClass: String, Sendable, Equatable {
    /// Points at something a reader can check against the code or a ledger:
    /// `commit`, `file`, `test`, `claimed-command`, `wiki`.
    case settling
    /// Reports what someone said or wrote down (`message`, `chat`, `ticket`,
    /// `doc`, pre-1.0 `command`), or is a kind this version doesn't know: it
    /// can prompt a check, but isn't one.
    case question
}

/// A piece of evidence attached to a TB.
public struct TruthEvidence: Sendable, Codable, Equatable {
    /// Open: a kind this version doesn't know is kept as written.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// A commit, by its hash.
        public static let commit: Kind = "commit"
        /// A file, usually with a line (`path:line`).
        public static let file: Kind = "file"
        /// A test, by its name or path.
        public static let test: Kind = "test"
        /// Command output recorded before 1.0, which nobody re-ran: it can't
        /// appear on a new write (stenographer records a submitted command as
        /// `claimedCommand`) and is question-class.
        public static let command: Kind = "command"
        /// A command line someone says they ran; `detail` holds the output
        /// they say they saw. Stenographer didn't run it.
        public static let claimedCommand: Kind = "claimed-command"
        /// The id of an entry in a truth ledger: this one or a teammate's. A
        /// team wiki page is a `doc`.
        public static let wiki: Kind = "wiki"
        /// A message in a conversation transcript, by its id.
        public static let message: Kind = "message"
        /// A chat message or thread (Slack, Teams, Discord).
        public static let chat: Kind = "chat"
        /// An issue or ticket (Jira, Linear, GitHub issues).
        public static let ticket: Kind = "ticket"
        /// A document or page outside the truth ledger: a design doc, a team wiki page, a README.
        public static let doc: Kind = "doc"

        public static let known: [Kind] = [.commit, .file, .test, .command, .claimedCommand, .wiki, .message, .chat, .ticket, .doc]

        /// The settling kinds; every other kind, known or not, is question-class.
        public static let settling: [Kind] = [.commit, .file, .test, .claimedCommand, .wiki]

        public var isKnown: Bool { Self.known.contains(self) }

        /// This kind's class. A kind this version doesn't know is
        /// question-class, whatever a newer writer meant by it: it fails closed.
        public var evidenceClass: TruthEvidenceClass { Self.settling.contains(self) ? .settling : .question }

        public var description: String { rawValue }
    }

    public let kind: Kind
    /// Commit sha, file/line, test name, command line, truth entry id,
    /// message id, chat message or thread, ticket, or document.
    public let ref: String
    /// What the evidence shows (e.g. captured command output).
    public let detail: String?

    public init(kind: Kind, ref: String, detail: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.detail = detail
    }

    /// Whether this item is settling-class evidence (`Kind.evidenceClass`).
    public var isSettling: Bool { kind.evidenceClass == .settling }
}

/// Machine-actionable verification hint carried by every UV.
public struct TruthVerifyBy: Sendable, Codable, Equatable {
    /// Open: a kind this version doesn't know is kept as written.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static let command: Kind = "command"
        public static let inspect: Kind = "inspect"
        public static let ask: Kind = "ask"
        public static let observe: Kind = "observe"

        public static let known: [Kind] = [.command, .inspect, .ask, .observe]

        public var description: String { rawValue }
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

    /// Stenographer's write-time rule (`TombstonedLiteralSchema`), which a
    /// submitted draft must pass: every present field non-blank once
    /// trimmed, and a literal without a `subject` must be a distinctive
    /// identifier — at least 4 UTF-16 code units and at least one ASCII
    /// letter, as stenographer's `value.length >= 4 && /[A-Za-z]/` counts
    /// them. A bare value like "30" can't be matched safely without naming
    /// what it's the value of. Returns nil when valid, else the reason.
    public func validationError() -> String? {
        let dead = ecmaScriptTrim(self.dead)
        if dead.isEmpty { return "a literal needs a dead value" }
        if let subject, ecmaScriptTrim(subject).isEmpty {
            return "a literal's subject can't be blank"
        }
        if let current, ecmaScriptTrim(current).isEmpty {
            return "a literal's current value can't be blank"
        }
        if subject == nil, !isDistinctiveIdentifier(dead) {
            return "a literal without a subject must be a distinctive identifier (≥4 chars, contains a letter) — name the subject of bare values"
        }
        return nil
    }
}

/// Stenographer's `isDistinctiveIdentifier`: `value.length >= 4 && /[A-Za-z]/.test(value)`
/// — UTF-16 code units, an ASCII letter.
func isDistinctiveIdentifier(_ value: String) -> Bool {
    value.utf16.count >= 4 && value.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
}

// MARK: - Where an entry came from

/// The TRANSITION line a reader read: an entry's status changed.
public struct TruthTransition: Sendable, Equatable {
    public let id: String
    public let seq: Int
    public let ts: String
    public let author: String
    /// The TB or UV whose status changed.
    public let target: String
    /// Its new status, as written (open string).
    public let status: String
    /// What caused the change: `kind` (open string) and the causing entry's id, or nil.
    public let causeKind: String
    public let causeRef: String?
    /// 1-based line number (blank lines count).
    public let line: Int
    public let file: String?
}

/// A TRANSITION read but not applied, and why.
public struct TruthHeldTransition: Sendable, Equatable {
    public let line: Int
    public let id: String
    public let reason: String
    public let file: String?
}

/// The line an entry was read from. An entry with a source serializes back
/// to exactly `text`, never a rewrite.
public struct TruthEntrySource: Sendable, Equatable {
    /// 1 (stenographer 0.x) or 2.
    public let version: Int
    /// The line exactly as read.
    public let text: String
    /// 1-based line number (blank lines count).
    public let line: Int
    public let seq: Int?
    public let hash: String?
    /// The `status` the line itself states (an entry's status may have been folded from a later TRANSITION).
    public let lineStatus: String?
    public let file: String?
    /// The TRANSITION that set the entry's current status, when one did.
    public var transition: TruthTransition?
}

/// Why a reader will not take an entry as truth, whatever its status. The
/// reasons' raw values are stenographer's reconciliation reasons (its import
/// files such lines as proposals for a person, and is stricter: it files any
/// line with a value it doesn't know).
public struct TruthInadmissible: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// Two lines (or two files) give the id different content: its
        /// fields compared as JCS, unknown fields included, the chain fields
        /// (`schemaVersion`, `seq`, `prevHash`, `hash`) and `x-steno` aside.
        case conflict
        /// A TB without a signer (a backfilled TB): never truth on its own.
        case unsigned
        /// No hash to check (a version 1 TB), or an identity the signer registry doesn't list.
        case unverifiable
        /// A TB an agent signed without a quorum whose members are all
        /// agents: agents settle claims only together, as two or more agent
        /// sessions agreeing from different angles within 15 minutes;
        /// otherwise a person signs it (truth format v2, "Agent quorum").
        case agentWithoutQuorum = "agent-without-quorum"
        /// A TB an agent signed that cites an evidence kind this version
        /// doesn't know, on its line or in its quorum, or that carries a link
        /// type it doesn't know in `x-steno.links`. The quorum rules don't
        /// refuse a line over such a value (it may be a newer writer's: a
        /// settling kind, say), so this reader can't tell that the members
        /// agree from different angles, and fails closed, however well the
        /// quorum keeps the rules otherwise (truth format v2, "Unknown values",
        /// "Agent quorum", "Evidence classes"). A person's TB may cite any kind.
        case unknownValue = "unknown-value"
    }

    public let reason: Reason
    public let detail: String
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
    /// The current status: the line's own, or the last TRANSITION's. nil
    /// when the line states none — not current truth (fail closed).
    public var status: TbStatus?
    /// Matchable dead literals (§12). Empty when the TB declares none.
    public let literals: [TruthTombstonedLiteral]
    /// The agent sessions that settled it together, when agents signed it
    /// (truth format v2, "Agent quorum"); nil when the line carries none.
    public let quorum: [TruthQuorumMember]?
    /// Opaque stenographer namespace (`x-steno`).
    public let xSteno: JSONValue?
    /// Fields this version doesn't define, kept as written.
    public var extra: [String: JSONValue]
    /// The line this entry was read from (nil for an entry built in code).
    public var source: TruthEntrySource?
    /// Set when a reader will not take this entry as truth.
    public var inadmissible: TruthInadmissible?

    public init(
        id: String,
        ts: String,
        author: String,
        claim: String,
        evidence: [TruthEvidence],
        signedBy: String?,
        status: TbStatus?,
        literals: [TruthTombstonedLiteral] = [],
        quorum: [TruthQuorumMember]? = nil,
        xSteno: JSONValue? = nil,
        extra: [String: JSONValue] = [:],
        source: TruthEntrySource? = nil,
        inadmissible: TruthInadmissible? = nil
    ) {
        self.id = id
        self.ts = ts
        self.author = author
        self.claim = claim
        self.evidence = evidence
        self.signedBy = signedBy
        self.status = status
        self.literals = literals
        self.quorum = quorum
        self.xSteno = xSteno
        self.extra = extra
        self.source = source
        self.inadmissible = inadmissible
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
    /// Id of a TB this UV disputes. While the UV is open it rides that TB,
    /// whatever the TB's recorded status.
    public let contests: String?
    /// The current status (see `TruthTbEntry.status`). nil: not current.
    public var status: UvStatus?
    public let xSteno: JSONValue?
    public var extra: [String: JSONValue]
    public var source: TruthEntrySource?
    public var inadmissible: TruthInadmissible?

    public init(
        id: String,
        ts: String,
        author: String,
        assertion: String,
        basis: String,
        verifyBy: TruthVerifyBy,
        contests: String?,
        status: UvStatus?,
        xSteno: JSONValue? = nil,
        extra: [String: JSONValue] = [:],
        source: TruthEntrySource? = nil,
        inadmissible: TruthInadmissible? = nil
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
        self.extra = extra
        self.source = source
        self.inadmissible = inadmissible
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

    /// `TB` or `UV`.
    public var type: String {
        switch self {
        case .tb: return "TB"
        case .uv: return "UV"
        }
    }

    /// The current status as written, or nil when there is none.
    public var statusValue: String? {
        switch self {
        case .tb(let entry): return entry.status?.rawValue
        case .uv(let entry): return entry.status?.rawValue
        }
    }

    public var source: TruthEntrySource? {
        switch self {
        case .tb(let entry): return entry.source
        case .uv(let entry): return entry.source
        }
    }

    public var inadmissible: TruthInadmissible? {
        switch self {
        case .tb(let entry): return entry.inadmissible
        case .uv(let entry): return entry.inadmissible
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
    /// Refuted/verified/struck UV, overridden/struck TB, an unknown or
    /// missing status, or an entry a reader won't admit — history, never citable.
    case history
}

/// Shipped verbatim from stenographer so consumers inherit identical rules.
public let consumptionRules = """
Consumption rules by confidence type:
- Active TB: treat as ground truth. A reviewer may block on it; a code agent may rely on it.
- Contested TB: ground truth with a visible asterisk — cite both the TB and the contesting UV.
- Open UV: FLAG, DON'T BLOCK. A finding grounded only in a UV is phrased as a question or heads-up, never a demanded change. If your current task can check the UV, file your verdict and evidence with resolve_uv: it settles only when another agent session agrees from a different angle (other evidence, another kind) within 15 minutes, or when a person rules.
- Refuted UV / overridden TB: retrievable for history, excluded from current-truth by default, never citable as support for a claim.
"""

/// Current truth partitioned by consumption action.
public struct TruthSelection: Sendable, Equatable {
    /// Active TBs with no open contest — ground truth.
    public let groundTruth: [TruthTbEntry]
    /// Contested TBs (and current TBs with an open contest) paired with their open contesting UVs — carry both.
    public let contested: [(tombstone: TruthTbEntry, contestedBy: [TruthUvEntry])]
    /// Open UVs — flagged, never presented as proven. Includes the ones riding a contested TB.
    public let unverified: [TruthUvEntry]
    /// Everything that is not current truth.
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

    /// Ids of the open UVs that ride a contested TB in this selection.
    public var attachedUvIds: Set<String> {
        Set(contested.flatMap { $0.contestedBy.map(\.id) })
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

// MARK: - Errors

public enum TruthError: Error, Equatable, CustomStringConvertible {
    case anonymousAuthor(String)
    case malformedLine(line: Int, reason: String)

    public var description: String {
        switch self {
        case .anonymousAuthor(let identity):
            return "anonymous or generic identities cannot write toward the truth ledger "
                + "(got \"\(identity)\") — use a registered human handle or agent identity"
        case .malformedLine(let line, let reason):
            return line > 0 ? "malformed ledger line \(line): \(reason)" : reason
        }
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
