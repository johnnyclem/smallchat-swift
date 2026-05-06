import Testing
import Foundation
@testable import SmallChatCore
import SmallChatEmbedding

@Suite("ComponentSelector")
struct ComponentSelectorTests {

    // MARK: - Struct basics

    @Test("equality and hashing based on canonical")
    func equalityOnCanonical() {
        let a = ComponentSelector(canonical: "com.example.header", vector: [1, 0], intentText: "header")
        let b = ComponentSelector(canonical: "com.example.header", vector: [0, 1], intentText: "title")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("different canonicals are not equal")
    func differentCanonicalsNotEqual() {
        let a = ComponentSelector(canonical: "com.example.header", vector: [1, 0], intentText: "header")
        let b = ComponentSelector(canonical: "com.example.footer", vector: [1, 0], intentText: "footer")
        #expect(a != b)
    }

    // MARK: - ComponentSelectorTable: intern deduplication

    @Test("intern dedup: identical canonical returns same selector")
    func internDedup() async throws {
        let index = MemoryVectorIndex()
        let embedder = DeterministicEmbedder()
        let table = ComponentSelectorTable(index: index, embedder: embedder, threshold: 0.95)

        let e1: [Float] = [1, 0, 0]
        let e2: [Float] = [1, 0, 0]
        let s1 = try await table.intern(embedding: e1, canonical: "com.app.button")
        let s2 = try await table.intern(embedding: e2, canonical: "com.app.button")

        #expect(s1 == s2)
        let size = await table.size
        #expect(size == 1)
    }

    @Test("intern dedup: high similarity merges to existing selector")
    func internSimilarityMerge() async throws {
        let index = MemoryVectorIndex()
        let embedder = DeterministicEmbedder()
        let table = ComponentSelectorTable(index: index, embedder: embedder, threshold: 0.95)

        // First intern
        let e1: [Float] = [1, 0, 0]
        let s1 = try await table.intern(embedding: e1, canonical: "com.app.cancel-button")

        // Very similar vector — should return the existing selector
        let e2: [Float] = [0.9999, 0.01, 0]
        let s2 = try await table.intern(embedding: e2, canonical: "com.app.cancel-button")

        #expect(s1.canonical == s2.canonical)
    }

    @Test("intern: two dissimilar canonicals are stored separately")
    func internDissimilar() async throws {
        let index = MemoryVectorIndex()
        let embedder = DeterministicEmbedder()
        let table = ComponentSelectorTable(index: index, embedder: embedder, threshold: 0.95)

        let e1: [Float] = [1, 0, 0]
        let e2: [Float] = [0, 1, 0]
        _ = try await table.intern(embedding: e1, canonical: "com.app.header")
        _ = try await table.intern(embedding: e2, canonical: "com.app.footer")

        let size = await table.size
        #expect(size == 2)
    }

    // MARK: - ComponentSelectorTable: resolve by intent

    @Test("resolve by intent: returns interned selector for matching intent")
    func resolveByIntent() async throws {
        let index = MemoryVectorIndex()
        let embedder = DeterministicEmbedder()
        let table = ComponentSelectorTable(index: index, embedder: embedder, threshold: 0.0)

        let e: [Float] = [1, 0, 0]
        let interned = try await table.intern(embedding: e, canonical: "com.app.header")

        let resolved = try await table.resolve(intent: "show the header")
        #expect(resolved != nil)
        #expect(resolved?.canonical == interned.canonical)
    }

    @Test("resolve returns nil when table is empty")
    func resolveEmptyTable() async throws {
        let index = MemoryVectorIndex()
        let embedder = DeterministicEmbedder()
        let table = ComponentSelectorTable(index: index, embedder: embedder, threshold: 0.95)

        let result = try await table.resolve(intent: "open header")
        #expect(result == nil)
    }
}

// MARK: - Test helpers

private struct DeterministicEmbedder: Embedder, Sendable {
    var dimensions: Int { 3 }
    func embed(_ text: String) async throws -> [Float] { [1, 0, 0] }
    func embedBatch(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 0, 0] } }
}
