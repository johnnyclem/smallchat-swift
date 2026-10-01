import Foundation

/// SelectorTable -- the table of compiled tool (and alias) selectors.
///
/// Like Objective-C's `sel_registerName`, it maps a canonical selector name
/// to one `ToolSelector` and keeps the vector index that tool resolution
/// searches. It holds tool selectors only: a runtime intent is embedded on
/// its own (`resolve(_:)`) and is never added to the table, the index or
/// any cache, so what an intent resolves to does not depend on which other
/// intents the process has seen (@smallchat/core 1.0 semantics).
public actor SelectorTable {
    private var selectors: [String: ToolSelector] = [:]
    private let index: any VectorIndex
    private let embedder: any Embedder
    private let threshold: Float

    public init(
        index: any VectorIndex,
        embedder: any Embedder,
        threshold: Float = 0.95
    ) {
        self.index = index
        self.embedder = embedder
        self.threshold = threshold
    }

    /// Intern a tool selector: if a tool selector with this canonical, or
    /// one semantically equivalent to it (cosine similarity >= threshold),
    /// is already in the table, return it; otherwise add a new one. Use
    /// `register(embedding:canonical:)` to keep two similar tools apart
    /// (the compiler and artifact loaders do).
    public func intern(embedding: [Float], canonical: String) async throws -> ToolSelector {
        if let existing = selectors[canonical] { return existing }

        let existing = try await index.search(query: embedding, topK: 1, threshold: threshold)
        if let match = existing.first, let sel = selectors[match.id] {
            return sel
        }
        return try await register(embedding: embedding, canonical: canonical)
    }

    /// Register a compiled tool or alias selector under its exact canonical
    /// name. Unlike `intern`, this never folds the selector into a
    /// semantically similar one: two distinct tools always get two distinct
    /// selectors. Registering an existing canonical returns the selector
    /// already in the table.
    public func register(embedding: [Float], canonical: String) async throws -> ToolSelector {
        if let existing = selectors[canonical] { return existing }
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

    /// Embed a natural language intent. The returned selector carries this
    /// exact text's own embedding, its display canonical and its identity
    /// key; the table and the vector index are left unchanged.
    public func resolve(_ intent: String) async throws -> ToolSelector {
        ToolSelector.intent(intent, vector: try await embedder.embed(intent))
    }

    /// The nearest registered tool selectors to `vector`, best first.
    ///
    /// Similarities are quantized (`quantizeScore`) before anything else: a
    /// selector is included when its quantized similarity is >= threshold,
    /// and equal quantized similarities are ordered by selector id (UTF-16
    /// code units), so the result -- including which selectors make the
    /// topK cut -- is the same whatever order they were registered in and
    /// whichever vector backend computed the distances. Index rows that are
    /// not registered selectors are skipped; the search widens until topK
    /// registered selectors are found (and every tie at the cut is seen) or
    /// the index is exhausted.
    public func searchTools(_ vector: [Float], topK: Int, threshold: Double) async throws -> [SelectorMatch] {
        guard topK > 0 else { return [] }
        func similarity(_ m: SelectorMatch) -> Double { quantizeScore(1 - Double(m.distance)) }
        // A raw similarity that rounds up to the threshold still counts.
        let rawThreshold = Float(threshold - scoreQuantum / 2)
        var fetchK = topK + 1
        while true {
            let raw = try await index.search(query: vector, topK: fetchK, threshold: rawThreshold)
            let exhausted = raw.count < fetchK
            let results = raw
                .filter { selectors[$0.id] != nil && similarity($0) >= threshold }
                .sorted {
                    let a = similarity($0), b = similarity($1)
                    return a != b ? a > b : $0.id.utf16.lexicographicallyPrecedes($1.id.utf16)
                }
            let lastFetched = raw.last.map(similarity) ?? -1
            let cut = results.count >= topK ? similarity(results[topK - 1]) : nil
            if exhausted || (cut != nil && lastFetched < cut!) {
                return Array(results.prefix(topK))
            }
            fetchK *= 2
        }
    }

    /// Look up a selector by its canonical name.
    public func get(_ canonical: String) -> ToolSelector? {
        selectors[canonical]
    }

    /// Number of registered tool selectors.
    public var size: Int { selectors.count }

    /// All registered tool selectors.
    public func all() -> [ToolSelector] {
        Array(selectors.values)
    }
}
