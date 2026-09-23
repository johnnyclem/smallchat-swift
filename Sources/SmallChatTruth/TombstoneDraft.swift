import Foundation

// MARK: - Authoring a tombstone
//
// A human who already knows a value is dead asserts it directly: a signed
// TB with evidence and the literals an objection can cite. It's written as
// an ordinary wiki JSONL line, which stenographer ingests through its
// existing `import_wiki_entries` path (literals validated there too) and
// which this app's own ledger reads immediately. No agent can take this
// path: it requires an accountable signer.

public struct TombstoneDraft: Sendable, Equatable {
    public var claim: String
    public var evidence: [TruthEvidence]
    public var literals: [TruthTombstonedLiteral]
    /// Who asserts it. Must be a specific person, not "system"/"assistant".
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
        }
        return out
    }

    /// The signed entry. Throws the first problem if the draft isn't ready.
    public func sign(now: Date = Date()) throws -> TruthTbEntry {
        if let first = problems().first { throw TruthError.malformedLine(line: 0, reason: first) }
        let who = signer.trimmingCharacters(in: .whitespacesAndNewlines)
        func clean(_ s: String?) -> String? {
            s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TruthTbEntry(
            id: ulid(now: now),
            ts: formatter.string(from: now),
            author: who,
            claim: claim.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: evidence.map { TruthEvidence(kind: $0.kind, ref: $0.ref.trimmingCharacters(in: .whitespaces), detail: clean($0.detail)) },
            signedBy: who,
            status: .active,
            literals: literals.map {
                TruthTombstonedLiteral(dead: $0.dead.trimmingCharacters(in: .whitespaces), subject: clean($0.subject), current: clean($0.current))
            }
        )
    }
}

extension TruthWiki {
    /// Append entries to a wiki JSONL file (created if missing), keeping the
    /// file newline-terminated so each entry stays on its own line.
    public static func append(_ entries: [TruthLedgerEntry], toFileAt path: String) throws {
        let lines = serialize(entries)
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var prefix = ""
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data("\n".utf8) { prefix = "\n" }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data((prefix + lines.joined(separator: "\n") + "\n").utf8))
    }
}
