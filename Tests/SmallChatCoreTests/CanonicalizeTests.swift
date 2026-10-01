import Testing
@testable import SmallChatCore

@Suite("Canonicalize")
struct CanonicalizeTests {
    @Test("Converts intent to colon-separated form")
    func basicCanonicalization() {
        let result = canonicalize("find my recent documents")
        #expect(result == "find:recent:documents")
    }

    @Test("Filters stopwords")
    func filtersStopwords() {
        let result = canonicalize("search for the documents in a folder")
        #expect(result == "search:documents:folder")
    }

    @Test("Returns unknown for empty input")
    func emptyInput() {
        let result = canonicalize("the a an")
        #expect(result == "unknown")
    }

    @Test("Lowercases input")
    func lowercases() {
        let result = canonicalize("Search Documents")
        #expect(result == "search:documents")
    }

    @Test("Removes non-alphanumeric characters")
    func removesSpecialChars() {
        let result = canonicalize("search! for @docs #now")
        #expect(result == "search:docs:now")
    }

    // MARK: - v0.3.0 Intent Sanitization Tests

    @Test("Sanitize strips null bytes")
    func sanitizeStripsNullBytes() {
        let input = "find\0my\0docs"
        let result = sanitizeIntent(input)
        #expect(result == "findmydocs")
    }

    @Test("Sanitize strips control characters")
    func sanitizeStripsControlChars() {
        let input = "find\u{01}docs\u{07}now"
        let result = sanitizeIntent(input)
        #expect(result == "finddocsnow")
    }

    @Test("Sanitize truncates long intents")
    func sanitizeTruncatesLong() {
        let longIntent = String(repeating: "a", count: 2000)
        let result = sanitizeIntent(longIntent)
        #expect(result.count <= maxIntentLength)
    }

    @Test("Sanitize collapses whitespace")
    func sanitizeCollapsesWhitespace() {
        let result = sanitizeIntent("find    my     docs")
        #expect(result == "find my docs")
    }

    @Test("Sanitize trims leading/trailing whitespace")
    func sanitizeTrimsWhitespace() {
        let result = sanitizeIntent("  find docs  ")
        #expect(result == "find docs")
    }

    @Test("ValidateIntent rejects empty string")
    func validateRejectsEmpty() {
        #expect(throws: IntentValidationError.self) {
            _ = try validateIntent("")
        }
    }

    @Test("ValidateIntent rejects whitespace-only string")
    func validateRejectsWhitespace() {
        #expect(throws: IntentValidationError.self) {
            _ = try validateIntent("   ")
        }
    }

    @Test("ValidateIntent accepts valid intent")
    func validateAcceptsValid() throws {
        let result = try validateIntent("find documents")
        #expect(result == "find documents")
    }

    @Test("Canonicalize keeps every token (no cap, as in @smallchat/core 1.0)")
    func canonicalizeKeepsAllTokens() {
        let manyWords = (0..<100).map { "word\($0)" }.joined(separator: " ")
        #expect(canonicalize(manyWords).split(separator: ":").count == 100)
    }

    @Test("intentKey keeps negations and punctuation apart, folds case and spacing")
    func intentKeys() {
        #expect(intentKey("  Delete   the LOGS ") == "delete the logs")
        #expect(intentKey("do not delete the logs") != intentKey("delete the logs"))
        #expect(intentKey("e\u{301}tat") == intentKey("\u{e9}tat"))
    }

    @Test("normalizePinPhrase is NFKC, lower case, collapsed whitespace")
    func pinPhrases() {
        #expect(normalizePinPhrase("Transfer  Funds") == "transfer funds")
        #expect(normalizePinPhrase("\u{FB01}le") == "file")
        #expect(normalizePinPhrase("do not transfer funds") != normalizePinPhrase("transfer funds"))
    }
}
