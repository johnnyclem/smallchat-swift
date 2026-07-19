import Foundation
import OrderedCollections

/// SelectorTable -- the interning table for semantic selectors.
///
/// Like Objective-C's `sel_registerName`, this ensures that semantically
/// equivalent intents resolve to the same cached `ToolSelector` value.
/// "Pointer equality" becomes "embedding similarity above threshold."
///
/// `selectors`/`index` hold only *compiled tool selectors*, interned via
/// `intern(embedding:canonical:)` at hydration/registration time. Runtime
/// intents resolved via `resolve(_:)` are looked up against that tool space
/// but are cached separately in a bounded, LRU-evicted `intentCache` --
/// they are never inserted into `selectors`/`index`. Mixing the two spaces
/// previously let every distinct intent a process ever saw accumulate
/// forever in the shared vector index, silently competing with real tools
/// for the fixed `topK` slots returned by similarity search. See
/// johnnyclem/smallchat-swift#36.
public actor SelectorTable {
    private var selectors: [String: ToolSelector] = [:]
    private let index: any VectorIndex
    private let embedder: any Embedder
    private let threshold: Float
    private let rateLimiter: SemanticRateLimiter?

    /// Bounded LRU cache of resolved intent selectors, keyed by canonical
    /// form. Kept entirely separate from `selectors`/`index` so intent
    /// volume can never grow the tool vector index or crowd out real tool
    /// candidates in similarity search.
    private var intentCache: OrderedDictionary<String, ToolSelector> = [:]
    private let intentCacheCapacity: Int

    public init(
        index: any VectorIndex,
        embedder: any Embedder,
        threshold: Float = 0.95,
        rateLimiter: SemanticRateLimiter? = nil,
        intentCacheCapacity: Int = 2048
    ) {
        self.index = index
        self.embedder = embedder
        self.threshold = threshold
        self.rateLimiter = rateLimiter
        self.intentCacheCapacity = max(1, intentCacheCapacity)
    }

    /// Look up a cached intent resolution, refreshing its LRU position.
    private func intentCacheGet(_ canonical: String) -> ToolSelector? {
        guard let sel = intentCache[canonical] else { return nil }
        intentCache.removeValue(forKey: canonical)
        intentCache[canonical] = sel
        return sel
    }

    /// Cache an intent resolution, evicting the least-recently-used entry
    /// if at capacity.
    private func intentCacheSet(_ canonical: String, _ selector: ToolSelector) {
        if intentCache.count >= intentCacheCapacity && intentCache[canonical] == nil {
            intentCache.removeFirst()
        }
        intentCache.removeValue(forKey: canonical)
        intentCache[canonical] = selector
    }

    /// Intern a *compiled tool* selector. If a semantically equivalent one
    /// exists (cosine similarity > threshold), return the existing one.
    ///
    /// This is the only path that writes into `selectors`/`index`. Callers
    /// resolving natural-language runtime intents should use `resolve(_:)`
    /// instead.
    public func intern(embedding: [Float], canonical: String) async throws -> ToolSelector {
        // Check for exact canonical match first (fast path)
        if let existing = selectors[canonical] { return existing }

        // Check for semantic match via vector index
        let existing = try await index.search(query: embedding, topK: 1, threshold: threshold)
        if let match = existing.first, let sel = selectors[match.id] {
            return sel
        }

        // New selector -- create and intern
        let parts = canonical.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let sel = ToolSelector(
            vector: embedding,
            canonical: canonical,
            parts: parts,
            arity: max(0, parts.count - 1)
        )

        selectors[canonical] = sel
        try await index.insert(id: canonical, vector: embedding)
        return sel
    }

    /// Resolve a natural language intent to a `ToolSelector`.
    ///
    /// Checks the semantic rate limiter before embedding. If the system
    /// is under vector flood, throws `VectorFloodError` without touching
    /// the embedder.
    ///
    /// Unlike `intern(embedding:canonical:)`, this never mutates the tool
    /// selector map or the shared vector index -- resolved intents are only
    /// cached in a bounded, LRU-evicted side table, so long-running
    /// processes don't accumulate unbounded state and repeated dispatch
    /// against many distinct intents can't dilute the tool vector index's
    /// fixed `topK` search window.
    public func resolve(_ intent: String) async throws -> ToolSelector {
        let canonical = canonicalize(intent)

        // Fast path: an exact tool selector already registered under this
        // canonical (e.g. the intent literally matches a tool's own name).
        if let existing = selectors[canonical] { return existing }

        // Fast path: already resolved this intent before.
        if let cached = intentCacheGet(canonical) { return cached }

        // Pre-embedding flood gate
        if let limiter = rateLimiter {
            let allowed = await limiter.check(canonical)
            if !allowed { throw VectorFloodError(canonical: canonical) }
        }

        let embedding = try await embedder.embed(intent)

        // Post-embedding: record for similarity tracking
        if let limiter = rateLimiter {
            await limiter.record(canonical, embedding)
            _ = await limiter.checkSimilarity()
        }

        // Check for a semantic match against *compiled tool* selectors only
        // (e.g. the intent phrasing nearly matches a tool's own canonical
        // text) so we can return that shared selector instance instead of
        // minting a new one.
        let matches = try await index.search(query: embedding, topK: 1, threshold: threshold)
        if let match = matches.first, let sel = selectors[match.id] {
            intentCacheSet(canonical, sel)
            return sel
        }

        let parts = canonical.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let sel = ToolSelector(
            vector: embedding,
            canonical: canonical,
            parts: parts,
            arity: max(0, parts.count - 1)
        )
        intentCacheSet(canonical, sel)
        return sel
    }

    /// Look up a selector by its canonical name.
    public func get(_ canonical: String) -> ToolSelector? {
        selectors[canonical]
    }

    /// Number of interned *tool* selectors (excludes cached intents).
    public var size: Int { selectors.count }

    /// All interned *tool* selectors (excludes cached intents).
    public func all() -> [ToolSelector] {
        Array(selectors.values)
    }

    /// Number of intents currently cached (bounded by `intentCacheCapacity`).
    public var cachedIntentCount: Int { intentCache.count }
}
