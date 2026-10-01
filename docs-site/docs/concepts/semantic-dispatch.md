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

### 4. Tier, verification and policy

The best match's score sets its tier: EXACT (>= 0.95), HIGH (>= 0.85), MEDIUM
(>= 0.75), LOW (>= 0.60). EXACT and HIGH matches run; a MEDIUM or LOW match runs only
after an LLM verifier approves it, and a destructive tool only at EXACT or from a
pinned phrase. Anything else is `needs-disambiguation` or `unresolved`: nothing runs,
and the caller gets the nearest tools to choose from by id. See
[Resolution Pipeline](./resolution-pipeline.md) for every step.

```swift
let resolution = try await runtime.resolve("find available flights to Tokyo")
// .resolved, chosen "flights/search_flights", tier .high -- nothing has run yet
let result = try await runtime.dispatchById("flights/search_flights", args: ["to": "Tokyo"])
```

## Canonical forms and identity keys

`canonicalize` turns an intent into a Smalltalk-style display form (punctuation
deleted, stopwords dropped):

```
"find recent documents"     → "find:recent:documents"
"don't delete the database" → "dont:delete:database"
```

It is for display only: it drops words such as "not", so different intents can share
a canonical form. Identity uses whole-text keys instead: `intentKey` (case, Unicode NFC
form and whitespace aside) keys the resolution cache, and `normalizePinPhrase` compares
intent pins.

## No intent interning

The `SelectorTable` holds compiled tool selectors only. A runtime intent is embedded on
its own and never inserted into the table or the vector index, so the tools a search
can return do not depend on which intents a process has seen, and a long-running
process keeps no state per intent.

## Resolution Cache

The `ResolutionCache` (LRU, default 1024 entries) remembers allowed resolutions of
intent dispatches, keyed by `intentKey`. It is version-aware: when a tool's schema or a
provider version changes, stale entries are invalidated. Pinned and destructive tools
are never cached, and every hit goes through the dispatch policy again, so a cached
resolution cannot run a tool that a fresh resolution would refuse.

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
| **Semantic dispatch** | **~0.1ms** (hash embedder) | **Zero** | Depends on the embedder; asks instead of guessing below HIGH | **Yes** |
