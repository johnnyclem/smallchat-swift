import Foundation
import Testing
@testable import SmallChatCore

/// Minimal ToolIMP stub for cache tests.
private final class CacheStubIMP: ToolIMP, @unchecked Sendable {
    let providerId: String
    let toolName: String
    let transportType: TransportType = .local
    let schema: ToolSchema? = nil

    init(providerId: String = "provider-a", toolName: String = "tool") {
        self.providerId = providerId
        self.toolName = toolName
    }

    func loadSchema() async throws -> ToolSchema { fatalError() }
    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        ToolResult(content: toolName)
    }
}

private func makeSelector(_ canonical: String) -> ToolSelector {
    ToolSelector(vector: [], canonical: canonical, parts: canonical.split(separator: ":").map(String.init), arity: 0)
}

@Suite("ResolutionCache")
struct ResolutionCacheTests {

    // MARK: - LRU Eviction

    @Test("Evicts oldest entry when at capacity")
    func lruEviction() async {
        let cache = ResolutionCache(maxSize: 3)
        let imp = CacheStubIMP()

        await cache.store(makeSelector("a"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("b"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("c"), imp: imp, confidence: 0.9)
        #expect(await cache.size == 3)

        // Adding a 4th should evict "a"
        await cache.store(makeSelector("d"), imp: imp, confidence: 0.9)
        #expect(await cache.size == 3)
        #expect(await cache.lookup(makeSelector("a")) == nil)
        #expect(await cache.lookup(makeSelector("d")) != nil)
    }

    @Test("LRU access refreshes entry position")
    func lruAccessRefreshes() async {
        let cache = ResolutionCache(maxSize: 3)
        let imp = CacheStubIMP()

        await cache.store(makeSelector("a"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("b"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("c"), imp: imp, confidence: 0.9)

        // Access "a" to refresh it
        _ = await cache.lookup(makeSelector("a"))

        // Now "b" is oldest, adding "d" should evict "b"
        await cache.store(makeSelector("d"), imp: imp, confidence: 0.9)
        #expect(await cache.lookup(makeSelector("b")) == nil)
        #expect(await cache.lookup(makeSelector("a")) != nil)
    }

    // MARK: - Staleness Detection

    @Test("Provider version change causes cache miss")
    func providerVersionStaleness() async {
        let cache = ResolutionCache(
            versionContext: CacheVersionContext(providerVersions: ["provider-a": "v1"])
        )
        let imp = CacheStubIMP(providerId: "provider-a")

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.9)
        #expect(await cache.lookup(makeSelector("x")) != nil)

        // Bump provider version
        await cache.setProviderVersion("provider-a", "v2")
        #expect(await cache.lookup(makeSelector("x")) == nil)
    }

    @Test("Model version change causes cache miss")
    func modelVersionStaleness() async {
        let cache = ResolutionCache(
            versionContext: CacheVersionContext(modelVersion: "gpt-4")
        )
        let imp = CacheStubIMP()

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.9)
        #expect(await cache.lookup(makeSelector("x")) != nil)

        await cache.setModelVersion("gpt-5")
        #expect(await cache.lookup(makeSelector("x")) == nil)
    }

    @Test("Schema fingerprint change causes cache miss")
    func schemaFingerprintStaleness() async {
        let cache = ResolutionCache(
            versionContext: CacheVersionContext(schemaFingerprints: ["provider-a": "abc123"])
        )
        let imp = CacheStubIMP(providerId: "provider-a")

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.9)
        #expect(await cache.lookup(makeSelector("x")) != nil)

        await cache.setSchemaFingerprint("provider-a", "def456")
        #expect(await cache.lookup(makeSelector("x")) == nil)
    }

    // MARK: - Version Tagging

    @Test("Stored entries are tagged with current version context")
    func versionTagging() async {
        let cache = ResolutionCache(
            versionContext: CacheVersionContext(
                providerVersions: ["p": "v1"],
                modelVersion: "m1",
                schemaFingerprints: ["p": "s1"]
            )
        )
        let imp = CacheStubIMP(providerId: "p")

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.9)
        let resolved = await cache.lookup(makeSelector("x"))
        #expect(resolved?.providerVersion == "v1")
        #expect(resolved?.modelVersion == "m1")
        #expect(resolved?.schemaFingerprint == "s1")
    }

    // MARK: - Confidence Filtering

    @Test("Low-confidence results are not cached")
    func lowConfidenceNotCached() async {
        let cache = ResolutionCache(minConfidence: 0.85)
        let imp = CacheStubIMP()

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.80)
        #expect(await cache.size == 0)
        #expect(await cache.lookup(makeSelector("x")) == nil)
    }

    @Test("High-confidence results are cached")
    func highConfidenceCached() async {
        let cache = ResolutionCache(minConfidence: 0.85)
        let imp = CacheStubIMP()

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.90)
        #expect(await cache.size == 1)
        #expect(await cache.lookup(makeSelector("x")) != nil)
    }

    // MARK: - Flush Operations

    @Test("flush clears all entries")
    func flushClearsAll() async {
        let cache = ResolutionCache()
        let imp = CacheStubIMP()

        await cache.store(makeSelector("a"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("b"), imp: imp, confidence: 0.9)
        #expect(await cache.size == 2)

        await cache.flush()
        #expect(await cache.size == 0)
    }

    @Test("flushProvider only removes that provider's entries")
    func flushProviderSelective() async {
        let cache = ResolutionCache()
        let impA = CacheStubIMP(providerId: "provider-a")
        let impB = CacheStubIMP(providerId: "provider-b")

        await cache.store(makeSelector("x"), imp: impA, confidence: 0.9)
        await cache.store(makeSelector("y"), imp: impB, confidence: 0.9)
        #expect(await cache.size == 2)

        await cache.flushProvider("provider-a")
        #expect(await cache.size == 1)
        #expect(await cache.lookup(makeSelector("x")) == nil)
        #expect(await cache.lookup(makeSelector("y")) != nil)
    }

    @Test("flushSelector removes a single entry")
    func flushSelectorRemovesOne() async {
        let cache = ResolutionCache()
        let imp = CacheStubIMP()

        await cache.store(makeSelector("a"), imp: imp, confidence: 0.9)
        await cache.store(makeSelector("b"), imp: imp, confidence: 0.9)

        await cache.flushSelector(makeSelector("a"))
        #expect(await cache.size == 1)
        #expect(await cache.lookup(makeSelector("a")) == nil)
        #expect(await cache.lookup(makeSelector("b")) != nil)
    }

    // MARK: - Invalidation Hooks

    @Test("Invalidation hook fires on flush")
    func invalidationHookFires() async {
        let cache = ResolutionCache()
        var firedEvents: [String] = []

        await cache.invalidateOn { event in
            switch event {
            case .flush:
                firedEvents.append("flush")
            case .provider(let id):
                firedEvents.append("provider:\(id)")
            case .selector(let sel):
                firedEvents.append("selector:\(sel.canonical)")
            case .stale(let reason, let key):
                firedEvents.append("stale:\(key)")
            }
        }

        await cache.flush()
        #expect(firedEvents == ["flush"])
    }

    // MARK: - Hit Count

    @Test("hitCount increments on each lookup")
    func hitCountIncrements() async {
        let cache = ResolutionCache()
        let imp = CacheStubIMP()

        await cache.store(makeSelector("x"), imp: imp, confidence: 0.9)

        let r1 = await cache.lookup(makeSelector("x"))
        #expect(r1?.hitCount == 2)  // store sets to 1, first lookup bumps to 2

        let r2 = await cache.lookup(makeSelector("x"))
        #expect(r2?.hitCount == 3)
    }
}
