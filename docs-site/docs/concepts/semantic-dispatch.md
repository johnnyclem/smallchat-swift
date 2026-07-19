---
sidebar_position: 2
title: Semantic Dispatch
---

# Semantic Dispatch

Semantic dispatch is the core innovation of smallchat. Instead of the LLM choosing from a list of tools (prompt-based routing), the runtime resolves natural language intents to tool implementations using vector similarity.

## The Problem with Tool Selection

Traditional approaches have the LLM select tools:

1. **All tools in context** — Every tool description goes into the prompt. With 50 tools, that's thousands of tokens burned every turn.
2. **Routing prompts** — You write prompts like "Given these categories, which one should handle this request?" Adding latency and another point of failure.
3. **Hard-coded routing** — `if intent.contains("flight")` — brittle, doesn't generalize.

## How Semantic Dispatch Works

smallchat treats tool selection as a **vector similarity problem**:

### 1. Embedding

Every tool selector gets a 384-dimensional vector embedding at compile time:

```
"search_flights" → [0.23, 0.15, -0.08, ..., 0.89]
"book_hotel"     → [0.11, -0.23, 0.45, ..., 0.34]
"read_file"      → [-0.12, 0.67, 0.23, ..., -0.56]
```

### 2. Intent Resolution

When an intent arrives at runtime, it's also embedded:

```
"find available flights to Tokyo" → [0.21, 0.18, -0.05, ..., 0.91]
```

### 3. Vector Search

Cosine similarity finds the closest selectors:

```
cos("find available flights", "search_flights") = 0.94  ← match!
cos("find available flights", "book_hotel")     = 0.31
cos("find available flights", "read_file")      = 0.12
```

### 4. Dispatch

The highest-similarity match above the threshold (default 0.75) wins. The runtime dispatches to that tool's implementation.

## Canonicalization

Before embedding, intents are canonicalized into a Smalltalk-style selector format:

```
"find recent documents"     → "find:recent:documents"
"search for flights to NYC" → "search:for:flights:to:nyc"
```

This normalization ensures consistent matching regardless of phrasing variations.

## Selector Interning

The `SelectorTable` deduplicates **compiled tool selectors**. If a tool's canonical name is registered and a later lookup (compile-time or an intent embedding at runtime) lands within the interning threshold (default 0.95) of it, that lookup resolves to the **same** tool selector rather than minting a new one:

```swift
// "search_flights" is a registered tool selector
"search flights"    → selector_42  // exact canonical match
"find flights"      → selector_42  // same! (embeds within 0.95 of the tool's own selector)
"book a hotel room" → selector_87  // a different registered tool
```

This means natural paraphrases of a tool's own name resolve to the same dispatch path and cache entry.

Only the compiled tool space is deduplicated this way. Runtime intents that *don't* land near an existing tool selector are cached in a separate, bounded, LRU-evicted intent cache — never inserted into the tool vector index itself. Earlier versions interned every resolved intent into the same table and index as compiled tools, which meant every distinct intent a long-running process ever saw was retained forever, diluting the fixed `topK` window that tool similarity search draws candidates from. Splitting the two spaces fixes both the unbounded growth and the crowding-out risk (see [smallchat-swift#36](https://github.com/johnnyclem/smallchat-swift/issues/36)).

## Resolution Cache

The `ResolutionCache` is an LRU cache (default 1024 entries) that stores resolved intent-to-tool mappings. It's version-aware — when a tool's schema changes or a new provider is registered, stale cache entries are automatically invalidated.

```
Cache hit:  ~0.001ms (direct lookup)
Cache miss: ~0.1ms  (embed + vector search + overload resolution)
```

## Overload Resolution

When multiple tools match the same selector, smallchat uses **overload resolution** (inspired by C++ function overloading) to pick the best match based on argument types:

```swift
// Two tools registered for "search" selector
search(query: String)              → TextSearchTool
search(query: String, limit: Int)  → PaginatedSearchTool

// Runtime resolves based on arguments provided
runtime.dispatch("search", args: ["query": "hello"])           → TextSearchTool
runtime.dispatch("search", args: ["query": "hello", "limit": 10]) → PaginatedSearchTool
```

Scoring priority:
1. **Exact type match** — highest score
2. **Superclass match** — via ISA chain
3. **Union type match** — compatible union types
4. **Any type match** — lowest score, catch-all

## Comparison with Other Approaches

| Approach | Latency | Token Cost | Accuracy | Scales |
|----------|---------|------------|----------|--------|
| All tools in prompt | High | O(n) tools | Degrades with n | No |
| Routing prompt | +1 LLM call | Medium | Variable | Somewhat |
| Hard-coded routing | Low | None | Brittle | No |
| **Semantic dispatch** | **~0.1ms** | **Zero** | **Consistent** | **Yes** |
