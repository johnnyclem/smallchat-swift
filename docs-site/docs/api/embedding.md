---
sidebar_position: 5
title: Embedding
---

# Embedding

<span class="module-badge">SmallChatEmbedding</span>

The embedding module provides vector embedding and similarity search for semantic tool dispatch. The `Embedder` and `VectorIndex` protocols live in `SmallChatCore`.

## Embedder Protocol

```swift
protocol Embedder: Sendable {
    var dimensions: Int { get }
    var fingerprint: EmbedderFingerprint? { get }   // default: nil
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]   // default: embed each text
}
```

The `fingerprint` identifies what produced the vectors (kind, model, model hash,
dimensions, max length, pooling, normalization). Artifact format 1.0 records the
compiling embedder's fingerprint, and a runtime refuses an artifact whose fingerprint
differs from its embedder's (`EmbedderMismatchError`). An embedder without a fingerprint
cannot compile or load 1.0 artifacts.

## LocalEmbedder

A fast hash embedder: FNV-1a over words and their character trigrams. It matches
spelling, not meaning, so it suits development and tests.

```swift
struct LocalEmbedder: Embedder, Sendable
```

### Initialization

```swift
init(dimensions: Int = 384)
```

Its fingerprint is `EmbedderFingerprint.hash(dims: dimensions)` (`hash` /
`smallchat-hash-v1`), the same as @smallchat/core's hash embedder, whose vectors it
reproduces (checked by `LocalEmbedderParityTests` and the artifact golden fixture).

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

Embed multiple strings:

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

1. Lower-case the text, keep only ASCII letters, digits and whitespace, and split it into words
2. Hash each word with FNV-1a over its UTF-16 code units and add 1.0 at that index
3. Hash each character trigram of the word (`"search"` → `sea`, `ear`, `arc`, `rch`) and add 0.5 at its index
4. L2-normalize the result (the norm in double precision)

Inputs that share words or trigrams get a higher cosine similarity. Characters outside
ASCII are dropped, so text in other scripts embeds poorly.

### Custom Embedder

For semantic matching, implement the `Embedder` protocol with a real model and give it
a fingerprint:

```swift
struct MyModelEmbedder: Embedder {
    let dimensions = 1536
    let fingerprint: EmbedderFingerprint? = EmbedderFingerprint(
        kind: "custom",
        model: "text-embedding-3-small",
        modelSha256: nil,
        dims: 1536,
        maxLength: nil,
        pooling: "none",
        normalize: true
    )

    func embed(_ text: String) async throws -> [Float] {
        try await myModelClient.embed(text)   // your embedding API
    }
}
```

## VectorIndex Protocol

```swift
protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float]) async throws
    func search(query: [Float], topK: Int, threshold: Float) async throws -> [SelectorMatch]
    func remove(id: String) async throws
    func size() async throws -> Int
}
```

### SelectorMatch

```swift
struct SelectorMatch: Sendable, Equatable {
    let id: String
    let distance: Float   // 1 - cosine similarity
}
```

## MemoryVectorIndex

An in-memory brute-force cosine similarity index, for registries of up to about 10,000 tools.

```swift
actor MemoryVectorIndex: VectorIndex
```

Similarities are computed in double precision from the stored float32 components, and
equal similarities are ordered by id, so results never depend on insertion order.

### Initialization

```swift
init()
```

### Methods

#### insert

Add (or replace) a vector:

```swift
func insert(id: String, vector: [Float])
```

#### search

Find the top-K most similar vectors whose cosine similarity is at least `threshold`:

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
// [SelectorMatch(id: "search:flights", distance: 0.06)]   similarity 0.94
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

For larger deployments, implement `VectorIndex` with an approximate nearest neighbor
library. Return candidates with their distance (`1 - similarity`), drop those below the
threshold, and order equal distances by id: resolution ranks what the index returns.

## VectorMath

Low-level vector operations (`SmallChatCore`): Accelerate on Apple platforms, a scalar
loop elsewhere.

```swift
// Cosine similarity between two vectors
let similarity = cosineSimilarity(vectorA, vectorB)

// The same in double precision (what MemoryVectorIndex uses)
let precise = cosineSimilarityDouble(vectorA, vectorB)

// L2-normalize a vector in place
l2Normalize(&vector)
```
