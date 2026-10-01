import Foundation
import SmallChatTruth

// MARK: - Stenographer
//
// Sits in every chat. Preloaded from the project wiki's truth ledger
// (stenographer's truth format v2 export, one stream per writer), it does
// two things:
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
    /// A stream was refused (a bad hash, a broken chain): nothing was loaded.
    public var refused: Bool

    public init(entries: [TruthLedgerEntry] = [], sources: [String] = [], errors: [String] = [], refused: Bool = false) {
        self.entries = entries
        self.sources = sources
        self.errors = errors
        self.refused = refused
    }

    public var selection: TruthSelection { TruthWiki.selectCurrentTruth(entries) }

    public var tombstones: [TruthTbEntry] {
        entries.compactMap { if case .tb(let tb) = $0 { return tb } else { return nil } }
    }

    /// Open UVs a reader admits: heads-ups, never demands.
    public var openClaims: [TruthUvEntry] {
        entries.compactMap { if case .uv(let uv) = $0, TruthWiki.classify($0) == .flag { return uv } else { return nil } }
    }

    /// Load and merge truth streams (wiki JSONL files, or directories of
    /// them): each file is one writer's stream, folded on its own, and each
    /// entry takes the most advanced status any file reached. If any file is
    /// refused (a bad hash, a broken chain), nothing is loaded — a stream
    /// that can't be read might hold the strike that matters — and the
    /// errors say why.
    public static func load(paths: [String], options: TruthReadOptions = TruthReadOptions()) -> TruthLedgerSnapshot {
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
        var streams: [(name: String, text: String)] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            streams.append((file, text))
        }
        let parsed = TruthWiki.parseFiles(streams, options: options)
        return TruthLedgerSnapshot(
            entries: parsed.entries,
            sources: files,
            errors: parsed.errors.map(\.description),
            refused: parsed.refused
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
                text: "\(objection.summary)\n> \(TruthEscaping.escapeUntrusted(objection.transcriptLine, singleLine: true))"
            ))
        }
        for uv in ledger.openClaims where reliesOn(text, claim: uv.assertion) {
            notes.append(StenographerNote(
                kind: .unverified,
                entryId: uv.id,
                text: "\(TruthCompaction.unverifiedMarker) This leans on an unverified claim: “\(field(uv.assertion))” "
                    + "(basis: \(field(uv.basis))). Verify by \(field(uv.verifyBy.kind.rawValue)): \(field(uv.verifyBy.value))"
            ))
        }
        return notes
    }

    /// A ledger field as untrusted text: one line, no forged truth markers.
    static func field(_ text: String) -> String {
        TruthEscaping.escapeUntrusted(text, singleLine: true)
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
    /// answers about *this* chat. The transcript is untrusted text: a
    /// message that reproduces a `[TB]` line or the truth heading is
    /// escaped, so it can't pass for the ledger in the brief.
    public static func prompt(question: String, recent: [ChatMessage], nameFor: (MessageAuthor) -> String) -> String {
        let lines = recent.suffix(30).map { "\(field(nameFor($0.author))): \(TruthEscaping.escapeUntrusted($0.text))" }
        return """
        Recent transcript (oldest first):
        \(lines.joined(separator: "\n"))

        The user asks: \(question)
        """
    }
}
