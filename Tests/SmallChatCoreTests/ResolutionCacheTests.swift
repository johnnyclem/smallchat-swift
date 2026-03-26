import Testing
import Foundation
@testable import SmallChatCore

@Suite("ResolutionCache")
struct ResolutionCacheTests {

    private func makeSelector(_ canonical: String) -> ToolSelector {
        ToolSelector(vector: [1.0, 0.0, 0.0], canonical: canonical, parts: canonical.split(separator: ":").map(String.init), arity: 0)
    }

    private func makeIMP(providerId: String = "test", toolName: String = "tool") -> MockIMP {
        MockIMP(providerId: providerId, toolName: toolName)
    }

    // MARK: - LRU eviction

    @Test("Evicts oldest entry when at capacity")
    func lruEviction() async {
        let cache = ResolutionCache(maxSize: 2, minConfidence: 0.0)

        let sel1 = makeSelector("a")
        let sel2 = makeSelector("b")
        let sel3 = makeSelector("c")

        await cache.store(sel1, imp: makeIMP(toolName: "a"), confidence: 0.9)
        await cache.store(sel2, imp: makeIMP(toolName: "b"), confidence: 0.9)
        await cache.store(sel3, imp: makeIMP(toolName: "c"), confidence: 0.9)

        // sel1 should have been evicted (oldest)
        let a = await cache.lookup(sel1)
        #expect(a == nil)

        let b = await cache.lookup(sel2)
        #expect(b != nil)

        let c = await cache.lookup(sel3)
        #expect(c != nil)
    }

    @Test("LRU promotes on access")
    func lruPromotes() async {
        let cache = ResolutionCache(maxSize: 2, minConfidence: 0.0)

        let sel1 = makeSelector("a")
        let sel2 = makeSelector("b")
        let sel3 = makeSelector("c")

        await cache.store(sel1, imp: makeIMP(toolName: "a"), confidence: 0.9)
        await cache.store(sel2, imp: makeIMP(toolName: "b"), confidence: 0.9)

        // Access sel1 to promote it
        _ = await cache.lookup(sel1)

        // Now store sel3 -- sel2 should be evicted (oldest unused)
        await cache.store(sel3, imp: makeIMP(toolName: "c"), confidence: 0.9)

        let a = await cache.lookup(sel1)
        #expect(a != nil)

        let b = await cache.lookup(sel2)
        #expect(b == nil)
    }

    // MARK: - Staleness detection

    @Test("Provider version change causes cache miss")
    func providerVersionStaleness() async {
        let cache = ResolutionCache(
            maxSize: 100,
            minConfidence: 0.0,
            versionContext: CacheVersionContext(providerVersions: ["test": "v1"])
        )

        let sel = makeSelector("tool:call")
        await cache.store(sel, imp: makeIMP(), confidence: 0.95)

        // Still valid before version change
        let hit = await cache.lookup(sel)
        #expect(hit != nil)

        // Change provider version
        await cache.setProviderVersion("test", "v2")

        let miss = await cache.lookup(sel)
        #expect(miss == nil)
    }

    @Test("Model version change causes cache miss")
    func modelVersionStaleness() async {
        let cache = ResolutionCache(
            maxSize: 100,
            minConfidence: 0.0,
            versionContext: CacheVersionContext(modelVersion: "m1")
        )

        let sel = makeSelector("tool:call")
        await cache.store(sel, imp: makeIMP(), confidence: 0.95)

        let hit = await cache.lookup(sel)
        #expect(hit != nil)

        await cache.setModelVersion("m2")

        let miss = await cache.lookup(sel)
        #expect(miss == nil)
    }

    @Test("Schema fingerprint change causes cache miss")
    func schemaFingerprintStaleness() async {
        let cache = ResolutionCache(
            maxSize: 100,
            minConfidence: 0.0,
            versionContext: CacheVersionContext(schemaFingerprints: ["test": "fp1"])
        )

        let sel = makeSelector("tool:call")
        await cache.store(sel, imp: makeIMP(), confidence: 0.95)

        let hit = await cache.lookup(sel)
        #expect(hit != nil)

        await cache.setSchemaFingerprint("test", "fp2")

        let miss = await cache.lookup(sel)
        #expect(miss == nil)
    }

    // MARK: - Version tagging

    @Test("Stored entries carry current version context")
    func versionTagging() async {
        let cache = ResolutionCache(
            maxSize: 100,
            minConfidence: 0.0,
            versionContext: CacheVersionContext(
                providerVersions: ["test": "v1"],
                modelVersion: "m1",
                schemaFingerprints: ["test": "fp1"]
            )
        )

        let sel = makeSelector("x")
        await cache.store(sel, imp: makeIMP(), confidence: 0.95)

        let entry = await cache.lookup(sel)
        #expect(entry?.providerVersion == "v1")
        #expect(entry?.modelVersion == "m1")
        #expect(entry?.schemaFingerprint == "fp1")
    }

    // MARK: - Confidence filtering

    @Test("Low-confidence results are not cached")
    func lowConfidenceFiltered() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.85)

        let sel = makeSelector("ambiguous")
        await cache.store(sel, imp: makeIMP(), confidence: 0.5)

        let result = await cache.lookup(sel)
        #expect(result == nil)
        #expect(await cache.size == 0)
    }

    // MARK: - Invalidation

    @Test("Flush clears all entries")
    func flushClearsAll() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.0)
        await cache.store(makeSelector("a"), imp: makeIMP(), confidence: 0.9)
        await cache.store(makeSelector("b"), imp: makeIMP(), confidence: 0.9)

        await cache.flush()
        #expect(await cache.size == 0)
    }

    @Test("flushProvider removes only matching provider entries")
    func flushProviderSelective() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.0)
        await cache.store(makeSelector("a"), imp: makeIMP(providerId: "p1"), confidence: 0.9)
        await cache.store(makeSelector("b"), imp: makeIMP(providerId: "p2"), confidence: 0.9)

        await cache.flushProvider("p1")
        #expect(await cache.size == 1)
        #expect(await cache.lookup(makeSelector("b")) != nil)
    }

    @Test("flushSelector removes specific entry")
    func flushSelectorSpecific() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.0)
        let sel = makeSelector("target")
        await cache.store(sel, imp: makeIMP(), confidence: 0.9)
        await cache.store(makeSelector("other"), imp: makeIMP(), confidence: 0.9)

        await cache.flushSelector(sel)
        #expect(await cache.lookup(sel) == nil)
        #expect(await cache.size == 1)
    }

    // MARK: - Invalidation hooks

    @Test("Invalidation hook fires on flush")
    func invalidationHookFires() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.0)

        var firedEvents: [String] = []
        await cache.invalidateOn { event in
            switch event {
            case .flush: firedEvents.append("flush")
            case .provider: firedEvents.append("provider")
            case .selector: firedEvents.append("selector")
            case .stale: firedEvents.append("stale")
            }
        }

        await cache.flush()
        #expect(firedEvents.contains("flush"))
    }

    // MARK: - Hit count

    @Test("Hit count increments on repeated lookups")
    func hitCountIncrements() async {
        let cache = ResolutionCache(maxSize: 100, minConfidence: 0.0)
        let sel = makeSelector("popular")
        await cache.store(sel, imp: makeIMP(), confidence: 0.95)

        _ = await cache.lookup(sel)
        _ = await cache.lookup(sel)
        let entry = await cache.lookup(sel)
        #expect(entry?.hitCount == 4) // 1 initial + 3 lookups
    }
}
