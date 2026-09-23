import Foundation
import SmallChatTruth

// MARK: - Stenographer
//
// Sits in every chat. Preloaded from the project wiki's truth ledger
// (stenographer's TB/UV JSONL export), it does two things:
//
//   1. Watches passively and for free: every message is checked locally
//      against tombstoned literals (objections) and open unverified claims
//      (reliance notes). Notes are shown to the user only — the
//      stenographer never writes into an agent's conversation.
//   2. Answers when asked (`@stenographer …`) through a headless Claude
//      session whose system prompt carries the ledger.

public struct StenographerNote: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The message asserts a tombstoned literal.
        case objection
        /// The message leans on an open, unverified claim.
        case unverified
    }

    public let kind: Kind
    public let entryId: String
    public let text: String
}

public struct TruthLedgerSnapshot: Sendable, Equatable {
    public var entries: [TruthLedgerEntry]
    public var sources: [String]
    public var errors: [String]

    public init(entries: [TruthLedgerEntry] = [], sources: [String] = [], errors: [String] = []) {
        self.entries = entries
        self.sources = sources
        self.errors = errors
    }

    public var selection: TruthSelection { TruthWiki.selectCurrentTruth(entries) }

    public var tombstones: [TruthTbEntry] {
        entries.compactMap { if case .tb(let tb) = $0 { return tb } else { return nil } }
    }

    public var openClaims: [TruthUvEntry] {
        entries.compactMap { if case .uv(let uv) = $0, uv.status == .open { return uv } else { return nil } }
    }

    /// Load and merge wiki JSONL files (or directories of them). Later
    /// files win for a repeated id, matching the append-only ledger rule.
    public static func load(paths: [String]) -> TruthLedgerSnapshot {
        let fm = FileManager.default
        var files: [String] = []
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(atPath: path)) ?? []
                files += children.filter { $0.hasSuffix(".jsonl") }.sorted().map { (path as NSString).appendingPathComponent($0) }
            } else {
                files.append(path)
            }
        }
        var lines: [String] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            lines += text.components(separatedBy: "\n")
        }
        let parsed = TruthWiki.parse(lines: lines)
        return TruthLedgerSnapshot(
            entries: parsed.entries,
            sources: files,
            errors: parsed.errors.map(\.description)
        )
    }
}

public enum Stenographer {

    // MARK: Watching

    /// Check one chat message. Pure and cheap — runs on every message.
    public static func observe(_ text: String, ledger: TruthLedgerSnapshot) -> [StenographerNote] {
        var notes: [StenographerNote] = []
        var seen = Set<String>()
        for objection in TruthObjections.check(text, against: ledger.tombstones) {
            let key = objection.tombstone.id + "|" + objection.literal.dead
            guard seen.insert(key).inserted else { continue }
            notes.append(StenographerNote(
                kind: .objection,
                entryId: objection.tombstone.id,
                text: "\(objection.summary)\n> \(objection.transcriptLine)"
            ))
        }
        for uv in ledger.openClaims where reliesOn(text, claim: uv.assertion) {
            notes.append(StenographerNote(
                kind: .unverified,
                entryId: uv.id,
                text: "\(TruthCompaction.unverifiedMarker) This leans on an unverified claim: “\(uv.assertion)” "
                    + "(basis: \(uv.basis)). Verify by \(uv.verifyBy.kind.rawValue): \(uv.verifyBy.value)"
            ))
        }
        return notes
    }

    /// Conservative lexical overlap: most of the claim's content words
    /// appear in the message. Precision over recall — a missed note is
    /// cheaper than a stenographer that cries wolf.
    static func reliesOn(_ text: String, claim: String) -> Bool {
        let claimWords = contentWords(claim)
        guard claimWords.count >= 3 else { return false }
        let overlap = claimWords.intersection(contentWords(text))
        return overlap.count >= 3 && Double(overlap.count) / Double(claimWords.count) >= 0.6
    }

    static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "been", "were", "will", "would", "should", "could",
        "there", "their", "they", "them", "then", "than", "into", "onto", "about", "which", "while",
        "when", "what", "where", "only", "also", "just", "some", "more", "most", "such", "each",
        "every", "does", "done", "because", "across", "safe", "still", "very", "your", "ours",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }
        return Set(words.map(String.init).filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    // MARK: Brief

    /// System prompt for the answering stenographer session.
    public static func brief(ledger: TruthLedgerSnapshot) -> String {
        """
        You are the stenographer in a smallchat group chat between a human and their \
        Claude Code agents. You are a court reporter: you do not do the work, you keep \
        the record straight. Answer the user's questions about what is established, \
        what is dead, and what is still unverified. Be brief and cite entry ids.

        Consumption rules for the ledger below:
        \(consumptionRules)

        \(TruthCompaction.renderSection(ledger.selection))
        """
    }

    /// The transcript excerpt sent with a question, so the stenographer
    /// answers about *this* chat.
    public static func prompt(question: String, recent: [ChatMessage], nameFor: (MessageAuthor) -> String) -> String {
        let lines = recent.suffix(30).map { "\(nameFor($0.author)): \($0.text)" }
        return """
        Recent transcript (oldest first):
        \(lines.joined(separator: "\n"))

        The user asks: \(question)
        """
    }
}
