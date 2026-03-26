import Testing
@testable import SmallChatCore

@Suite("IntentPinRegistry")
struct IntentPinRegistryTests {

    // MARK: - Exact match

    @Test("Exact policy accepts exact canonical match")
    func exactMatchAccepts() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:account", policy: .exact))

        let match = registry.checkExact("delete:account")
        #expect(match != nil)
        #expect(match?.verdict == .accept)
        #expect(match?.policy == .exact)
    }

    @Test("Exact policy returns nil for unrelated canonical")
    func exactMatchReturnsNilForUnrelated() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:account", policy: .exact))

        let match = registry.checkExact("list:users")
        #expect(match == nil)
    }

    @Test("Exact policy rejects similarity match for non-exact canonical")
    func exactPolicyRejectsSimilarityNonExact() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:account", policy: .exact))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:account",
            similarity: 0.99,
            intentCanonical: "remove:account"
        )
        #expect(match != nil)
        #expect(match?.verdict == .reject)
        #expect(match?.policy == .exact)
    }

    @Test("Exact policy accepts similarity check when canonicals match exactly")
    func exactPolicyAcceptsSimilarityExactCanonical() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:account", policy: .exact))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:account",
            similarity: 0.95,
            intentCanonical: "delete:account"
        )
        #expect(match != nil)
        #expect(match?.verdict == .accept)
    }

    // MARK: - Elevated threshold

    @Test("Elevated policy accepts high similarity")
    func elevatedAcceptsHighSimilarity() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "transfer:funds", policy: .elevated))

        let match = registry.checkSimilarity(
            candidateCanonical: "transfer:funds",
            similarity: 0.99,
            intentCanonical: "send:money"
        )
        #expect(match != nil)
        #expect(match?.verdict == .accept)
        #expect(match?.policy == .elevated)
        #expect(match?.similarity == 0.99)
    }

    @Test("Elevated policy rejects below threshold")
    func elevatedRejectsBelowThreshold() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "transfer:funds", policy: .elevated))

        let match = registry.checkSimilarity(
            candidateCanonical: "transfer:funds",
            similarity: 0.90,
            intentCanonical: "send:money"
        )
        #expect(match != nil)
        #expect(match?.verdict == .reject)
        #expect(match?.requiredThreshold == 0.98)
    }

    @Test("Elevated policy uses custom threshold")
    func elevatedCustomThreshold() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "transfer:funds", policy: .elevated, threshold: 0.95))

        let accept = registry.checkSimilarity(
            candidateCanonical: "transfer:funds",
            similarity: 0.96,
            intentCanonical: "send:money"
        )
        #expect(accept?.verdict == .accept)
        #expect(accept?.requiredThreshold == 0.95)

        let reject = registry.checkSimilarity(
            candidateCanonical: "transfer:funds",
            similarity: 0.94,
            intentCanonical: "send:money"
        )
        #expect(reject?.verdict == .reject)
    }

    // MARK: - Alias resolution

    @Test("Alias resolves to pinned canonical via checkExact")
    func aliasResolution() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:account",
            policy: .exact,
            aliases: ["remove account", "destroy my account"]
        ))

        // "remove account" canonicalizes to "remove:account"
        let match = registry.checkExact("remove:account")
        #expect(match != nil)
        #expect(match?.canonical == "delete:account")
        #expect(match?.verdict == .accept)
    }

    @Test("Alias resolves via similarity check for exact policy")
    func aliasSimilarityExactPolicy() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:account",
            policy: .exact,
            aliases: ["remove account"]
        ))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:account",
            similarity: 0.97,
            intentCanonical: "remove:account"
        )
        #expect(match?.verdict == .accept)
    }

    // MARK: - Rejection scenarios

    @Test("Similarity check returns nil for unpinned candidate")
    func similarityNilForUnpinned() {
        let registry = IntentPinRegistry()
        let match = registry.checkSimilarity(
            candidateCanonical: "unknown:selector",
            similarity: 1.0,
            intentCanonical: "unknown:selector"
        )
        #expect(match == nil)
    }

    // MARK: - Management

    @Test("Pin and unpin lifecycle")
    func pinUnpinLifecycle() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "test:selector", policy: .exact, aliases: ["test alias"]))

        #expect(registry.isPinned("test:selector"))
        #expect(registry.size == 1)
        #expect(registry.getPin("test:selector")?.policy == .exact)

        registry.unpin("test:selector")
        #expect(!registry.isPinned("test:selector"))
        #expect(registry.size == 0)
        // Alias should also be cleaned up
        #expect(registry.checkExact("test:alias") == nil)
    }

    @Test("pinnedCanonicals returns all pinned names")
    func pinnedCanonicals() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "a", policy: .exact))
        registry.pin(IntentPin(canonical: "b", policy: .elevated))

        let pinned = Set(registry.pinnedCanonicals())
        #expect(pinned == ["a", "b"])
    }
}
