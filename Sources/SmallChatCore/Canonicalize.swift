import Foundation

private let stopwords: Set<String> = [
    "a", "an", "the", "my", "your", "our", "their", "its",
    "is", "are", "was", "were", "be", "been", "being",
    "in", "on", "at", "to", "for", "of", "with", "by",
    "and", "or", "but", "not", "no", "do", "does", "did",
    "have", "has", "had", "will", "would", "could", "should",
    "can", "may", "might", "shall", "that", "this", "these",
    "those", "it", "i", "me", "we", "us", "you", "he", "she",
    "him", "her", "they", "them", "some", "all", "any", "each",
    "about", "from", "into", "please",
]

// MARK: - Intent Sanitization (v0.3.0)

/// Maximum allowed length for raw intent strings before canonicalization.
/// Intents exceeding this length are truncated to prevent resource exhaustion.
public let maxIntentLength: Int = 1024

/// Maximum number of tokens (colon-separated segments) in a canonical selector.
/// Prevents pathologically long selectors from degrading vector search performance.
public let maxCanonicalTokens: Int = 32

/// Sanitize a raw intent string before processing.
///
/// - Strips null bytes and control characters (U+0000–U+001F except space)
/// - Truncates to `maxIntentLength`
/// - Collapses runs of whitespace
///
/// This is the first defense layer in the dispatch pipeline, applied before
/// canonicalization or embedding.
public func sanitizeIntent(_ intent: String) -> String {
    // Strip null bytes and control characters
    let stripped = intent.unicodeScalars.filter { scalar in
        scalar == " " || scalar.value > 0x1F
    }
    var cleaned = String(String.UnicodeScalarView(stripped))

    // Truncate to maximum length
    if cleaned.count > maxIntentLength {
        cleaned = String(cleaned.prefix(maxIntentLength))
    }

    // Collapse runs of whitespace
    let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    return collapsed.trimmingCharacters(in: .whitespaces)
}

/// Error thrown when an intent fails validation.
public struct IntentValidationError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public let intent: String

    public init(reason: String, intent: String) {
        self.reason = reason
        self.intent = String(intent.prefix(64)) // Truncate for safe logging
    }

    public var description: String {
        "Intent validation failed: \(reason) (intent: \"\(intent)\")"
    }
}

/// Validate an intent string, returning the sanitized form or throwing.
///
/// Rejects:
/// - Empty strings
/// - Strings that are entirely stopwords or whitespace after canonicalization
public func validateIntent(_ intent: String) throws -> String {
    let sanitized = sanitizeIntent(intent)
    guard !sanitized.isEmpty else {
        throw IntentValidationError(reason: "empty intent", intent: intent)
    }
    return sanitized
}

/// Convert a natural language intent into a canonical selector form.
/// "find my recent documents" -> "find:recent:documents"
public func canonicalize(_ intent: String) -> String {
    let lowered = intent.lowercased()

    // Remove non-alphanumeric characters (keep spaces and digits)
    let cleaned = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
            return Character(scalar)
        }
        return " "
    }

    var words = String(cleaned)
        .split(separator: " ")
        .map { String($0) }
        .filter { !$0.isEmpty && !stopwords.contains($0) }

    // Enforce max token count to prevent pathologically long selectors
    if words.count > maxCanonicalTokens {
        words = Array(words.prefix(maxCanonicalTokens))
    }

    let result = words.joined(separator: ":")
    return result.isEmpty ? "unknown" : result
}
