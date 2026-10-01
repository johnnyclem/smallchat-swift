import SmallChatCore

/// In-memory vector index using brute-force cosine similarity.
/// Sufficient for small-to-medium registries (< 10K tools).
///
/// Similarities are computed in double precision from the stored float32
/// components, as @smallchat/core's in-memory index computes them, and
/// equal distances are ordered by id so results never depend on insertion
/// order.
public actor MemoryVectorIndex: VectorIndex {
    private var vectors: [String: [Float]] = [:]

    public init() {}

    public func insert(id: String, vector: [Float]) {
        vectors[id] = vector
    }

    public func search(query: [Float], topK: Int, threshold: Float) -> [SelectorMatch] {
        var results: [(id: String, similarity: Double)] = []

        for (id, vector) in vectors where vector.count == query.count {
            let similarity = cosineSimilarityDouble(query, vector)
            if similarity >= Double(threshold) {
                results.append((id, similarity))
            }
        }

        results.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.id.utf16.lexicographicallyPrecedes($1.id.utf16) }
        return results.prefix(max(0, topK)).map { SelectorMatch(id: $0.id, distance: Float(1 - $0.similarity)) }
    }

    public func remove(id: String) {
        vectors.removeValue(forKey: id)
    }

    public func size() -> Int {
        vectors.count
    }
}
