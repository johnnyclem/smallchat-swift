import Foundation

/// ComponentSelectorTable -- interning table for UI component selectors.
///
/// Parallel to `SelectorTable` but for the App/UI layer.
/// Like `sel_registerName`, ensures semantically equivalent component
/// descriptions resolve to the same `ComponentSelector` value.
public actor ComponentSelectorTable {
    private var selectors: [String: ComponentSelector] = [:]
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

    // MARK: - Intern

    /// Intern a component selector. Returns an existing one when cosine
    /// similarity ≥ threshold (deduplication).
    public func intern(embedding: [Float], canonical: String) async throws -> ComponentSelector {
        if let existing = selectors[canonical] { return existing }

        let matches = try await index.search(query: embedding, topK: 1, threshold: threshold)
        if let match = matches.first, let sel = selectors[match.id] {
            return sel
        }

        let sel = ComponentSelector(
            canonical: canonical,
            vector: embedding,
            intentText: canonical
        )
        selectors[canonical] = sel
        try await index.insert(id: canonical, vector: embedding)
        return sel
    }

    /// Intern with an explicit intent text (for human-readable component descriptions).
    public func intern(
        embedding: [Float],
        canonical: String,
        intentText: String
    ) async throws -> ComponentSelector {
        if let existing = selectors[canonical] { return existing }

        let matches = try await index.search(query: embedding, topK: 1, threshold: threshold)
        if let match = matches.first, let sel = selectors[match.id] {
            return sel
        }

        let sel = ComponentSelector(canonical: canonical, vector: embedding, intentText: intentText)
        selectors[canonical] = sel
        try await index.insert(id: canonical, vector: embedding)
        return sel
    }

    // MARK: - Resolve

    /// Resolve a natural language intent to the closest interned component.
    /// Returns `nil` when no selector scores above threshold.
    public func resolve(intent: String) async throws -> ComponentSelector? {
        let embedding = try await embedder.embed(intent)
        let matches = try await index.search(query: embedding, topK: 1, threshold: threshold)
        guard let match = matches.first else { return nil }
        return selectors[match.id]
    }

    /// Look up by exact canonical.
    public func get(_ canonical: String) -> ComponentSelector? {
        selectors[canonical]
    }

    public var size: Int { selectors.count }

    public func all() -> [ComponentSelector] {
        Array(selectors.values)
    }
}
