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

## Selector Table

The `SelectorTable` holds the selectors of compiled tools and their aliases.

- `register(embedding:canonical:)` adds a selector under its exact canonical name and
  never folds it into a similar one: two distinct tools always get two selectors. The
  compiler and the artifact loaders use it.
- `intern(embedding:canonical:)` returns an existing selector within the table's
  threshold (0.95 by default) instead of adding a new one, for code that wants
  near-identical selectors merged.
- `resolve(intent)` embeds a runtime intent and returns a selector carrying its own
  vector. The table and the vector index are left unchanged: intents are never
  interned.
- `searchTools(vector, topK:, threshold:)` returns the nearest registered selectors,
  with scores quantized to 1e-4 and ties ordered by selector id.

## Selector Namespacing

The `SelectorNamespace` protects core system selectors from being overridden by plugins:

```swift
let namespace = SelectorNamespace()
namespace.protect("tools:list")
namespace.protect("health:check")

// Plugin trying to register "tools:list" → SelectorShadowingError
```

## Intent Pinning

The `IntentPinRegistry` guards sensitive tools against semantic collisions. A pin
names a tool selector and a policy:

- **`exact`** — only the pin's own phrases (its canonical and aliases, compared as
  whole phrases after NFKC, lower case and whitespace collapsing) resolve to the tool.
- **`elevated`** — the intent's own embedding must reach the pin's threshold (0.98 by
  default).

```swift
let pins = IntentPinRegistry()
pins.pin(IntentPin(canonical: "account.delete_account", policy: .exact, aliases: ["delete my account"]))

// "delete my account"        → the pinned tool (still subject to the dispatch policy)
// "remove my account"        → not the pinned tool, however similar it embeds
// "do not delete my account" → not the pinned tool
```

Pass pins to a runtime with `RuntimeOptions(intentPins:)`.

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
