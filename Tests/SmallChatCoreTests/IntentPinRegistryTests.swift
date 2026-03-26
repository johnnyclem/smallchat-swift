import Testing
@testable import SmallChatCore

@Suite("IntentPinRegistry")
struct IntentPinRegistryTests {

    // MARK: - Exact Match

    @Test("Exact policy accepts canonical match")
    func exactMatchAccepts() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:user", policy: .exact))

        let match = registry.checkExact("delete:user")
        #expect(match != nil)
        #expect(match?.verdict == .accept)
        #expect(match?.policy == .exact)
    }

    @Test("Exact policy rejects non-matching canonical")
    func exactMatchRejectsNonMatch() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:user", policy: .exact))

        let match = registry.checkExact("delete:user:data")
        #expect(match == nil)
    }

    @Test("checkExact returns nil for unpinned selector")
    func checkExactReturnsNilForUnpinned() {
        let registry = IntentPinRegistry()
        let match = registry.checkExact("anything")
        #expect(match == nil)
    }

    // MARK: - Elevated Threshold

    @Test("Elevated policy accepts similarity above threshold")
    func elevatedAcceptsAboveThreshold() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:user", policy: .elevated, threshold: 0.95))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.96,
            intentCanonical: "remove:user"
        )
        #expect(match != nil)
        #expect(match?.verdict == .accept)
        #expect(match?.policy == .elevated)
        #expect(match?.similarity == 0.96)
        #expect(match?.requiredThreshold == 0.95)
    }

    @Test("Elevated policy rejects similarity below threshold")
    func elevatedRejectsBelowThreshold() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:user", policy: .elevated, threshold: 0.95))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.90,
            intentCanonical: "remove:user"
        )
        #expect(match != nil)
        #expect(match?.verdict == .reject)
    }

    @Test("Elevated policy uses default threshold of 0.98 when none specified")
    func elevatedUsesDefaultThreshold() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "delete:user", policy: .elevated))

        let rejectMatch = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.97,
            intentCanonical: "remove:user"
        )
        #expect(rejectMatch?.verdict == .reject)
        #expect(rejectMatch?.requiredThreshold == 0.98)

        let acceptMatch = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.99,
            intentCanonical: "remove:user"
        )
        #expect(acceptMatch?.verdict == .accept)
    }

    // MARK: - Alias Resolution

    @Test("Alias resolves to pinned canonical via checkExact")
    func aliasResolvesExact() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:user",
            policy: .exact,
            aliases: ["remove user", "erase user"]
        ))

        // "remove user" canonicalizes to "remove:user"
        let match = registry.checkExact(canonicalize("remove user"))
        #expect(match != nil)
        #expect(match?.verdict == .accept)
        #expect(match?.canonical == "delete:user")
    }

    @Test("Alias resolves in similarity check for exact policy")
    func aliasResolvesSimilarityExactPolicy() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:user",
            policy: .exact,
            aliases: ["remove user"]
        ))

        let aliasCanonical = canonicalize("remove user")
        let match = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.95,
            intentCanonical: aliasCanonical
        )
        #expect(match?.verdict == .accept)
    }

    @Test("Non-alias similar string rejected under exact policy via similarity check")
    func nonAliasRejectedUnderExactPolicy() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:user",
            policy: .exact,
            aliases: ["remove user"]
        ))

        let match = registry.checkSimilarity(
            candidateCanonical: "delete:user",
            similarity: 0.99,
            intentCanonical: "destroy:user"
        )
        #expect(match?.verdict == .reject)
    }

    // MARK: - Rejection

    @Test("Similarity check on exact-pinned selector rejects non-exact non-alias")
    func exactPolicyRejectsSimilarButNotExact() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "transfer:funds", policy: .exact))

        let match = registry.checkSimilarity(
            candidateCanonical: "transfer:funds",
            similarity: 0.97,
            intentCanonical: "send:funds"
        )
        #expect(match != nil)
        #expect(match?.verdict == .reject)
    }

    @Test("checkSimilarity returns nil for unknown candidate")
    func checkSimilarityNilForUnknown() {
        let registry = IntentPinRegistry()
        let match = registry.checkSimilarity(
            candidateCanonical: "unknown:selector",
            similarity: 1.0,
            intentCanonical: "unknown:selector"
        )
        #expect(match == nil)
    }

    // MARK: - Pin Management

    @Test("Unpin removes pin and aliases")
    func unpinRemovesPinAndAliases() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(
            canonical: "delete:user",
            policy: .exact,
            aliases: ["remove user"]
        ))
        #expect(registry.size == 1)
        #expect(registry.isPinned("delete:user"))

        registry.unpin("delete:user")
        #expect(registry.size == 0)
        #expect(!registry.isPinned("delete:user"))

        let aliasMatch = registry.checkExact(canonicalize("remove user"))
        #expect(aliasMatch == nil)
    }

    @Test("pinnedCanonicals returns all pinned keys")
    func pinnedCanonicalsReturnsAll() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "a", policy: .exact))
        registry.pin(IntentPin(canonical: "b", policy: .elevated))

        let keys = registry.pinnedCanonicals().sorted()
        #expect(keys == ["a", "b"])
    }

    @Test("getPin returns the pin entry")
    func getPinReturnsEntry() {
        let registry = IntentPinRegistry()
        registry.pin(IntentPin(canonical: "x", policy: .elevated, threshold: 0.90))

        let pin = registry.getPin("x")
        #expect(pin != nil)
        #expect(pin?.policy == .elevated)
        #expect(pin?.threshold == 0.90)
    }
}
