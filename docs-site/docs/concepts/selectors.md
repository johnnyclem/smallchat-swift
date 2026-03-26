---
sidebar_position: 4
title: Selectors
---

# Selectors

A `ToolSelector` is the semantic identifier for a tool — it carries both a human-readable canonical form and a vector embedding for similarity-based resolution.

## Structure

```swift
struct ToolSelector: Sendable, Equatable, Hashable {
    let vector: [Float]     // 384-dimensional embedding
    let canonical: String   // e.g., "search:flights"
    let parts: [String]     // ["search", "flights"]
    let arity: Int          // 2
}
```

## Canonicalization

Raw intents are transformed into a canonical selector format inspired by Smalltalk keyword messages:

```
"find recent documents"           → "find:recent:documents"
"search for available flights"    → "search:for:available:flights"
"read the file contents"          → "read:the:file:contents"
```

The `Canonicalize` module handles this transformation:
- Lowercases all text
- Splits on whitespace
- Joins with colons
- Strips articles and filler words (configurable)

## Embedding

Each canonical selector gets a vector embedding. The default `LocalEmbedder` uses FNV-1a hashing with trigram decomposition to produce a 384-dimensional vector:

```swift
let embedder = LocalEmbedder(dimensions: 384)
let vector = try await embedder.embed("search flights")
// [0.23, 0.15, -0.08, ..., 0.89]
```

## Selector Table (Interning)

The `SelectorTable` is an interning table that deduplicates selectors. Two intents that embed to sufficiently similar vectors (cosine similarity > threshold) resolve to the same selector:

```swift
// These might all intern to the same selector:
"search flights"      → selector_42
"find flights"        → selector_42 (similarity 0.97 > 0.95 threshold)
"look up flights"     → selector_42 (similarity 0.96 > 0.95 threshold)

// This would be different:
"book a hotel"        → selector_87 (similarity 0.31 < 0.95 threshold)
```

Benefits:
- Natural language paraphrases share dispatch paths
- Cache entries are reused across phrasings
- Reduces vector index size

## Selector Namespacing

The `SelectorNamespace` protects core system selectors from being overridden by plugins:

```swift
let namespace = SelectorNamespace()
namespace.protect("tools:list")
namespace.protect("health:check")

// Plugin trying to register "tools:list" → SelectorShadowingError
```

## Intent Pinning

The `IntentPinRegistry` prevents semantic collision attacks on sensitive selectors. Pins can enforce:

- **Exact match** — Only the exact canonical form resolves
- **Elevated threshold** — Requires higher similarity (e.g., 0.99) for resolution

```swift
// Pin "delete:account" to exact match only
registry.pin("delete:account", policy: .exact)

// "remove my account" won't resolve to "delete:account"
// even if vector similarity is high
```

## Arity

The arity of a selector is the number of parts (colon-separated segments). It's used as a tiebreaker in overload resolution — when two selectors have equal similarity, the one with matching arity wins.

## Creating Selectors

### From the Embedder

```swift
let vector = try await embedder.embed("search flights")
let selector = ToolSelector(
    vector: vector,
    canonical: "search:flights",
    parts: ["search", "flights"],
    arity: 2
)
```

### From the Compiler

The `ToolCompiler` creates selectors automatically during the EMBED phase:

```swift
let compiler = ToolCompiler(embedder: embedder, vectorIndex: vectorIndex)
let result = try await compiler.compile(manifests)
// Selectors are created for all tool definitions
```

### From the Runtime

The runtime creates selectors on-the-fly during dispatch:

```swift
// This internally embeds "find flights" and creates/interns a selector
let result = try await runtime.dispatch("find flights", args: [:])
```
