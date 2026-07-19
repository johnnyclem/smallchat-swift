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

The vector is checked against the `SelectorTable`'s compiled tool selectors. If it's sufficiently similar to an existing tool selector (cosine similarity > 0.95), that tool selector is reused. Otherwise the intent gets its own `ToolSelector` value, cached in a bounded, LRU-evicted intent cache that's kept separate from the tool selector table and vector index — intents never get inserted into either, so they can't accumulate unbounded state or crowd real tools out of the top-K window in step 6.

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

## Tiered Dispatch (0.5.0+)

`tieredDispatch` wraps the pipeline above with confidence-tier classification (`DispatchTier`: `.exact`, `.high`, `.medium`, `.low`, `.none`), each with distinct behavior:

| Tier | Behavior |
|------|----------|
| `.exact` / `.high` | Execute immediately |
| `.medium` | Run pre-flight `verifyCandidate`; on failure, downgrade to `.low` (or error, under `strict`) |
| `.low` | Attempt rule-based `decomposeIntent`; on failure, fall through to refinement |
| `.none` | Emit a `ToolRefinement` (`tool_refinement_needed`) |

### Behavior without an `LLMClient`

`tieredDispatch` takes an `LLMClient` (default `NoOpLLMClient`). Every stage degrades to a deterministic, non-LLM strategy rather than skipping its safety check:

- **`.medium` verification** (`verifyCandidate`) still validates required arguments against the tool's schema and computes a keyword-overlap score between the intent and the tool's name/description. Only when *both* pass — and no `LLMClient` is available to weigh in further — is the dispatch allowed to proceed.
- **`.low` decomposition** (`decomposeIntent`) only splits on explicit rule-based conjunctions ("then", "and then", "; ", etc.). If no conjunction is found and no `LLMClient` is configured, it does **not** fall through to executing the top match — it returns to `makeRefinement`, which asks the user to disambiguate.

In short: running without an `LLMClient` makes tier classification coarser (verification and decomposition lose their LLM-assisted strategies), but it does not turn `.medium`/`.low` into silent auto-execute paths. If you *do* want an even stricter posture for destructive tools, set `DispatchConfig.strict = true` so any tier below `.high` returns a `StrictAmbiguityError` instead of dispatching.

### Threshold calibration

The default `DispatchConfig` thresholds (`exactThreshold: 0.98`, `highThreshold: 0.85`, `mediumThreshold: 0.70`, `lowThreshold: 0.55`, `vectorSearchThreshold: 0.60`) assume a relatively high-contrast embedding space. Lower-contrast sentence embedders — `all-MiniLM-L6-v2` in particular — commonly score clear, correct-tool paraphrases in the 0.60–0.74 range, which the defaults classify as `.low` even though the match is unambiguous. If you're embedding with MiniLM (or seeing most of your traffic land in `.low`/`.none` despite good matches), start from `DispatchConfig.miniLM` instead of the plain default and tune from there against your own toolkit:

```swift
let config = DispatchConfig.miniLM
let context = DispatchContext(..., dispatchConfig: config)
```

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
