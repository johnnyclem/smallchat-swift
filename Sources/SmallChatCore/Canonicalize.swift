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

// MARK: - Display canonical and identity keys (@smallchat/core 1.0)

/// Convert a natural language intent into a canonical selector form, for
/// display: "find my recent documents" -> "find:recent:documents".
///
/// Unicode NFC, lower case, every character that is not a letter, number,
/// mark or whitespace deleted (so "foo-bar" -> "foobar" and "créer" stays
/// "créer"), split on whitespace, stopwords (including "not") dropped,
/// joined with ":". Same rules as @smallchat/core's `canonicalize()`.
///
/// It drops words such as "not", so two different intents can share a
/// canonical form: never use it as an identity key -- use `intentKey(_:)`
/// (cache, feedback) or `normalizePinPhrase(_:)` (intent pins).
public func canonicalize(_ intent: String) -> String {
    let lowered = intent.precomposedStringWithCanonicalMapping.lowercased()
    var words: [String] = []
    var current = String.UnicodeScalarView()
    func flush() {
        if !current.isEmpty {
            let word = String(current)
            if !stopwords.contains(word) { words.append(word) }
            current = String.UnicodeScalarView()
        }
    }
    for scalar in lowered.unicodeScalars {
        if isECMAScriptWhitespace(scalar) {
            flush()
        } else if isLetterNumberOrMark(scalar) {
            current.append(scalar)
        }
        // anything else is deleted (not a separator)
    }
    flush()
    let result = words.joined(separator: ":")
    return result.isEmpty ? "unknown" : result
}

/// The identity of an intent: its full text in Unicode NFC, trimmed, runs
/// of whitespace collapsed to one space, lower case. Nothing else is
/// removed -- negations, stopwords, punctuation and non-Latin scripts all
/// keep two intents apart. The resolution cache keys on it. Same rules as
/// @smallchat/core's `intentKey()`.
public func intentKey(_ intent: String) -> String {
    collapseECMAScriptWhitespace(intent.precomposedStringWithCanonicalMapping)
        .lowercased()
        .precomposedStringWithCanonicalMapping
}

/// The form pinned phrases are compared in: Unicode NFKC, lower case,
/// trimmed, internal whitespace collapsed to one space. Nothing else is
/// removed, so negations and qualifiers keep two phrases apart ("do not
/// transfer funds" is not the phrase "transfer funds"). Same rules as
/// @smallchat/core's `normalizePinPhrase()`.
public func normalizePinPhrase(_ text: String) -> String {
    collapseECMAScriptWhitespace(text.precomposedStringWithCompatibilityMapping.lowercased())
}

/// Trim, and collapse every run of ECMAScript whitespace to one space.
private func collapseECMAScriptWhitespace(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in text.unicodeScalars {
        if isECMAScriptWhitespace(scalar) {
            pendingSpace = !out.isEmpty
        } else {
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
    }
    return String(out)
}

/// The ECMAScript `\s` class (WhiteSpace and LineTerminator), which is also
/// what `String.prototype.trim` removes.
public func isECMAScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
         0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

/// `\p{L}`, `\p{N}` or `\p{M}`.
private func isLetterNumberOrMark(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber,
         .nonspacingMark, .spacingMark, .enclosingMark:
        return true
    default:
        return false
    }
}
