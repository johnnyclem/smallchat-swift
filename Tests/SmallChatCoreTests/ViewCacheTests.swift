import Testing
@testable import SmallChatCore

@Suite("ViewCache")
struct ViewCacheTests {

    private func makeSelector(_ canonical: String) -> ComponentSelector {
        ComponentSelector(canonical: canonical, vector: [1, 0, 0], intentText: canonical)
    }

    private func makeView(appId: String = "app", uri: String = "ui://app/index.html", version: String? = nil) -> CachedView {
        CachedView(appId: appId, uri: uri, content: "<html/>", appVersion: version)
    }

    // MARK: - LRU eviction

    @Test("Evicts oldest entry when at capacity")
    func lruEviction() async {
        let cache = ViewCache(maxSize: 2)
        let sel1 = makeSelector("a")
        let sel2 = makeSelector("b")
        let sel3 = makeSelector("c")

        await cache.store(sel1, view: makeView(uri: "ui://a"))
        await cache.store(sel2, view: makeView(uri: "ui://b"))
        await cache.store(sel3, view: makeView(uri: "ui://c"))

        let a = await cache.lookup(sel1)
        #expect(a == nil)
        let b = await cache.lookup(sel2)
        #expect(b != nil)
        let c = await cache.lookup(sel3)
        #expect(c != nil)
    }

    @Test("LRU promotes on access")
    func lruPromotes() async {
        let cache = ViewCache(maxSize: 2)
        let sel1 = makeSelector("a")
        let sel2 = makeSelector("b")
        let sel3 = makeSelector("c")

        await cache.store(sel1, view: makeView(uri: "ui://a"))
        await cache.store(sel2, view: makeView(uri: "ui://b"))
        // Access sel1 to promote it
        _ = await cache.lookup(sel1)
        // Now store sel3 — sel2 should be evicted
        await cache.store(sel3, view: makeView(uri: "ui://c"))

        let a = await cache.lookup(sel1)
        #expect(a != nil)
        let b = await cache.lookup(sel2)
        #expect(b == nil)
    }

    // MARK: - Version tagging

    @Test("version tagging: appVersion stored with entry")
    func versionTagging() async {
        let cache = ViewCache(maxSize: 10)
        await cache.setAppVersion("app", "v1")
        let sel = makeSelector("x")
        await cache.store(sel, view: makeView(version: "v1"))
        let entry = await cache.lookup(sel)
        #expect(entry?.appVersion == "v1")
    }

    @Test("stale entry: appVersion mismatch causes miss")
    func appVersionStaleness() async {
        let cache = ViewCache(maxSize: 10)
        await cache.setAppVersion("app", "v1")

        let sel = makeSelector("x")
        await cache.store(sel, view: makeView(version: "v1"))

        // Valid before version change
        let hit = await cache.lookup(sel)
        #expect(hit != nil)

        // Change version — entry becomes stale
        await cache.setAppVersion("app", "v2")
        let miss = await cache.lookup(sel)
        #expect(miss == nil)
    }

    // MARK: - Invalidation

    @Test("flush clears all entries")
    func flushClearsAll() async {
        let cache = ViewCache(maxSize: 10)
        await cache.store(makeSelector("a"), view: makeView())
        await cache.store(makeSelector("b"), view: makeView())
        await cache.flush()
        let size = await cache.size
        #expect(size == 0)
    }

    @Test("flushApp removes only matching app entries")
    func flushApp() async {
        let cache = ViewCache(maxSize: 10)
        let selA = makeSelector("a")
        let selB = makeSelector("b")
        await cache.store(selA, view: CachedView(appId: "app1", uri: "ui://app1/index.html", content: ""))
        await cache.store(selB, view: CachedView(appId: "app2", uri: "ui://app2/index.html", content: ""))

        await cache.flushApp("app1")
        let size = await cache.size
        #expect(size == 1)
        let b = await cache.lookup(selB)
        #expect(b != nil)
    }
}
