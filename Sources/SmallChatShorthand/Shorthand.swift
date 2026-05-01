import Foundation

// MARK: - SmallChatShorthand
//
// Shared text/NLP primitives extracted from compaction, CRDT, and
// importance modules in TS PR #58 (`@shorthand/core`). Kept deliberately
// small and dependency-free so any of those modules can pull from it.

// MARK: - Tokens

public enum Shorthand {

    /// Lowercased word tokens (length >= `minLength`) with optional
    /// stop-word filtering. Punctuation, whitespace, and digits are
    /// treated as separators.
    public static func tokens(
        in text: String,
        minLength: Int = 3,
        removeStopWords: Bool = true
    ) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch == "_" {
                cur.append(ch)
            } else if !cur.isEmpty {
                if cur.count >= minLength, !(removeStopWords && stopWords.contains(cur)) {
                    out.append(cur)
                }
                cur = ""
            }
        }
        if cur.count >= minLength, !(removeStopWords && stopWords.contains(cur)) {
            out.append(cur)
        }
        return out
    }

    /// Sentence-level split. Crude but stable -- splits on `.`, `!`, `?`,
    /// `\n` and trims whitespace.
    public static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let trimmed = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        let trimmed = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    // MARK: - Similarity

    /// Jaccard similarity over two token sets. Returns 0 when either set
    /// is empty.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    /// Cosine similarity between two equal-length numeric vectors.
    /// Returns 0 if either vector is zero-length or all-zero.
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        if na == 0 || nb == 0 { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: - Hashing

    /// Stable 64-bit FNV-1a content fingerprint. Useful for de-duplication
    /// without pulling in a real cryptographic hash.
    public static func contentHash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// Convenience: hex string form of `contentHash`.
    public static func contentHashHex(_ text: String) -> String {
        String(contentHash(text), radix: 16)
    }
}

// MARK: - Stop-word list

private let stopWords: Set<String> = [
    "the", "and", "for", "from", "with", "into", "this", "that", "what",
    "where", "when", "which", "have", "has", "had", "are", "was", "were",
    "you", "your", "our", "their", "his", "her", "its", "they", "them",
    "how", "why", "all", "any", "some", "show", "find", "get", "give",
    "tell", "make", "but", "not", "out", "about", "than", "then",
]
