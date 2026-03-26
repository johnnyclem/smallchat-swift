---
sidebar_position: 5
title: Resolution Pipeline
---

# Resolution Pipeline

The resolution pipeline is the sequence of steps that transform a natural language intent into a resolved tool implementation. This is the equivalent of `objc_msgSend` in the Objective-C runtime.

## Pipeline Steps

### 1. Canonicalization

The raw intent string is normalized:

```
"Find me some recent documents" → "find:me:some:recent:documents"
```

### 2. Embedding

The canonical form is embedded into a 384-dimensional vector:

```
"find:me:some:recent:documents" → [0.23, 0.15, ..., 0.89]
```

### 3. Selector Interning

The vector is checked against the `SelectorTable`. If a sufficiently similar selector already exists (cosine similarity > 0.95), it's reused. Otherwise, a new selector is created and interned.

### 4. Intent Pin Check (Fast Path)

The `IntentPinRegistry` is checked first. If the selector has an exact pin, only the pinned tool can match. This is a security mechanism for sensitive operations.

### 5. Cache Lookup

The `ResolutionCache` (LRU, default 1024 entries) is checked. Cache entries include version information — if the tool's schema or the provider version has changed since the entry was cached, it's treated as a miss.

```swift
// Cache hit: ~0.001ms
// Cache miss: continue to step 6
```

### 6. Vector Index Search

On cache miss, the `VectorIndex` is searched for the top-K (default 5) most similar selectors above the minimum threshold (default 0.75):

```swift
let matches = await vectorIndex.search(
    query: selector.vector,
    topK: 5,
    threshold: 0.75
)
// Returns: [(selectorId, similarity)]
```

### 7. Overload Resolution

If the top match has overloads, the runtime scores each overload against the provided arguments:

| Score | Match Type |
|-------|-----------|
| 4 | Exact type match |
| 3 | Superclass match |
| 2 | Union type match |
| 1 | Any type (catch-all) |

Tiebreakers:
1. Higher total score wins
2. Equal score → prefer developer-defined over semantic overloads
3. Still tied → prefer higher arity match
4. Still tied → `OverloadAmbiguityError`

### 8. Signature Validation

The resolved overload's parameter signature is validated against the provided arguments. This prevents type confusion attacks where an adversarial intent tricks the runtime into calling a tool with unexpected argument types.

### 9. ISA Chain Traversal

If the tool class can't handle the selector, the runtime walks up the superclass chain:

```
FileTools (miss)
  → IOTools (miss)
    → BaseTools (hit!)
```

### 10. Forwarding Chain

If the ISA chain is exhausted, the forwarding chain engages:

1. **Broadened search** — Lower the similarity threshold and search again
2. **LLM disambiguation** — (Stub) Ask the LLM to disambiguate between near-matches
3. **UnrecognizedIntent** — No resolution found

### 11. Cache Population

Successful resolutions are stored in the cache with the current version stamps.

### 12. Execution

The resolved `ToolIMP` is executed with the provided arguments:

```swift
let result = try await imp.execute(args: args)
```

## Streaming Variant

The streaming pipeline (`smallchatDispatchStream`) yields `DispatchEvent` values at each stage:

```swift
.resolving(intent: "find flights")
.toolStart(toolName: "search_flights", providerId: "flights", confidence: 0.94, selector: "search:flights")
.chunk(content: ..., index: 0)
.chunk(content: ..., index: 1)
.done(result: ToolResult(...))
```

The execution phase selects the best streaming tier:
1. **InferenceIMP** — Token-level deltas (`.inferenceDelta`)
2. **StreamableIMP** — Chunk-level results (`.chunk`)
3. **ToolIMP** — Single-shot, wrapped in `.done`

## Error Cases

| Error | Cause |
|-------|-------|
| `UnrecognizedIntent` | No selector matched above threshold |
| `OverloadAmbiguityError` | Multiple overloads scored equally |
| `SignatureValidationError` | Arguments don't match resolved signature |
| `SelectorShadowingError` | Plugin tried to override protected selector |
| `VectorFloodError` | Semantic rate limiter triggered |

## Performance Characteristics

| Operation | Typical Latency |
|-----------|----------------|
| Canonicalization | ~0.01ms |
| Embedding (LocalEmbedder) | ~0.05ms |
| Cache hit | ~0.001ms |
| Vector search (1000 tools) | ~0.1ms |
| Overload resolution | ~0.01ms |
| **Total (cache hit)** | **~0.07ms** |
| **Total (cache miss)** | **~0.2ms** |
