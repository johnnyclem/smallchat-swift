---
sidebar_position: 5
title: Embedding
---

# Embedding

<span class="module-badge">SmallChatEmbedding</span>

The embedding module provides vector embedding and similarity search for semantic tool dispatch.

## Embedder Protocol

```swift
protocol Embedder: Sendable {
    var dimensions: Int { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}
```

## LocalEmbedder

A fast, deterministic embedder using FNV-1a hashing with trigram decomposition. Suitable for development and testing.

```swift
struct LocalEmbedder: Embedder, Sendable
```

### Initialization

```swift
init(dimensions: Int = 384)
```

### Methods

#### embed

Embed a single text string:

```swift
func embed(_ text: String) async throws -> [Float]
```

```swift
let embedder = LocalEmbedder()
let vector = try await embedder.embed("search flights")
// [Float] with 384 dimensions, L2-normalized
```

#### embedBatch

Embed multiple strings efficiently:

```swift
func embedBatch(_ texts: [String]) async throws -> [[Float]]
```

```swift
let vectors = try await embedder.embedBatch([
    "search flights",
    "book hotel",
    "read file"
])
```

### How It Works

1. Tokenize input into trigrams: `"search"` → `["sea", "ear", "arc", "rch"]`
2. Hash each trigram with FNV-1a
3. Accumulate into a fixed-dimension vector
4. L2-normalize the result

This produces consistent embeddings where semantically similar inputs (sharing trigrams) have higher cosine similarity.

### Custom Embedder

For production, implement the `Embedder` protocol with a real model:

```swift
final class OpenAIEmbedder: Embedder, @unchecked Sendable {
    let dimensions = 1536

    func embed(_ text: String) async throws -> [Float] {
        // Call OpenAI embeddings API
        let response = try await openai.embeddings.create(
            model: "text-embedding-3-small",
            input: text
        )
        return response.data[0].embedding
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let response = try await openai.embeddings.create(
            model: "text-embedding-3-small",
            input: texts
        )
        return response.data.map(\.embedding)
    }
}
```

## VectorIndex Protocol

```swift
protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float]) async
    func search(query: [Float], topK: Int, threshold: Float) async -> [SelectorMatch]
    func remove(id: String) async
    func size() async -> Int
}
```

### SelectorMatch

```swift
struct SelectorMatch {
    let id: String
    let similarity: Float
}
```

## MemoryVectorIndex

An in-memory brute-force cosine similarity index. Suitable for up to ~10,000 tools.

```swift
actor MemoryVectorIndex: VectorIndex
```

### Initialization

```swift
init()
```

### Methods

#### insert

Add a vector to the index:

```swift
func insert(id: String, vector: [Float])
```

#### search

Find the top-K most similar vectors above a threshold:

```swift
func search(query: [Float], topK: Int, threshold: Float) -> [SelectorMatch]
```

```swift
let index = MemoryVectorIndex()
await index.insert(id: "search:flights", vector: flightVector)
await index.insert(id: "book:hotel", vector: hotelVector)

let matches = await index.search(
    query: queryVector,
    topK: 5,
    threshold: 0.75
)
// [SelectorMatch(id: "search:flights", similarity: 0.94)]
```

#### remove

Remove a vector from the index:

```swift
func remove(id: String)
```

#### size

Get the number of indexed vectors:

```swift
func size() -> Int
```

### Custom Vector Index

For larger deployments, implement `VectorIndex` with an ANN library:

```swift
actor HNSWVectorIndex: VectorIndex {
    // Use hnswlib or similar for approximate nearest neighbor search
    // Scales to millions of vectors with sub-millisecond search

    func search(query: [Float], topK: Int, threshold: Float) -> [SelectorMatch] {
        // ANN search implementation
    }
}
```

## VectorMath

Low-level vector operations using Apple's Accelerate framework:

```swift
// Cosine similarity between two vectors
let similarity = cosineSimilarity(vectorA, vectorB)

// L2 normalize a vector in-place
l2Normalize(&vector)
```

These are optimized via BLAS and run on the CPU's vector units.
