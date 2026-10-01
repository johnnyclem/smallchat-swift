---
sidebar_position: 1
title: Architecture
---

# Architecture

smallchat-swift borrows its architecture from the Smalltalk/Objective-C runtime. Tools are objects. Intents are messages. Dispatch is semantic.

## The Core Idea

In Objective-C, when you write `[object doSomething]`, the runtime resolves `doSomething` to a function pointer (IMP) through the class's dispatch table. If the class doesn't implement it, the runtime walks the superclass chain.

smallchat does the same thing — but with natural language intents instead of compiled selectors:

```
User intent "find recent docs"
  → Embed the intent: [0.23, 0.15, ..., 0.89] (384 dims)
  → Vector search: the 5 nearest tool selectors at or above 0.60
  → Overloads (by argument types), tier, verification, dispatch policy
  → resolved: run exactly that tool; otherwise ask the caller to choose
```

## Runtime Mapping

| Objective-C / Smalltalk | smallchat-swift | Purpose |
|-------------------------|-----------------|---------|
| Class | `ToolClass` | Groups related tools |
| Selector | `ToolSelector` | Semantic identifier with embedded vector |
| IMP (method pointer) | `ToolIMP` protocol | Tool implementation |
| `objc_msgSend` | `resolve` + `dispatchById` | Resolution (runs nothing), then exactly one call |
| Method cache | `ResolutionCache` | LRU cache, version-aware |
| ISA chain | Superclass traversal | Method lookup for a matched selector |
| Category | Provider extensions via `loadCategory()` | Extend existing classes |
| Method swizzling | `runtime.swizzle()` | Hot-reload, testing |

## Module Architecture

```
SmallChat (umbrella)
├── SmallChatCore          ← Type system, selectors, dispatch tables
├── SmallChatRuntime       ← Dispatch pipeline, fluent API
│   └── depends on Core
├── SmallChatCompiler      ← 4-phase compilation
│   └── depends on Core
├── SmallChatEmbedding     ← Embedder, vector index
│   └── depends on Core
├── SmallChatTransport     ← HTTP, SSE, stdio, auth, middleware
│   └── depends on Core, NIO
├── SmallChatMCP           ← MCP server, sessions, rate limiting
│   └── depends on Core, Runtime, Transport, SQLite, NIO
├── SmallChatChannel       ← Claude Code integration
│   └── depends on Core, MCP
└── SmallChatCLI           ← Command-line interface
    └── depends on all modules
```

## Concurrency Model

smallchat-swift uses Swift's structured concurrency throughout:

- **Actors** — `ToolRuntime`, `DispatchContext`, `ResolutionCache`, `SelectorTable`, `MemoryVectorIndex`, `MCPServer`, `ChannelServer` are all actors for thread-safe isolated state
- **Sendable types** — All core value types (`ToolSelector`, `ToolResult`, `DispatchEvent`, `ToolSchema`) conform to `Sendable`
- **Locks for hot paths** — `SelectorNamespace` and `IntentPinRegistry` use `OSAllocatedUnfairLock` for synchronous hot-path access where actor isolation would add unnecessary overhead
- **AsyncThrowingStream** — Streaming APIs use `AsyncThrowingStream` for backpressure-aware event delivery

## Data Flow

### Compilation Flow

```
MCP Manifests / OpenAPI Specs
        │
        ▼
   ┌─────────┐
   │  PARSE   │  Extract tool definitions
   └────┬─────┘
        │
        ▼
   ┌─────────┐
   │  EMBED   │  Generate vectors, intern selectors
   └────┬─────┘
        │
        ▼
   ┌─────────┐
   │  LINK    │  Build dispatch tables, detect collisions
   └────┬─────┘
        │
        ▼
   ┌─────────┐
   │ OUTPUT   │  Serialize to JSON artifact
   └─────────┘
```

### Runtime Flow

```
Natural Language Intent
        │
        ▼
   Pinned phrase? (whole-phrase match)
        │ no
        ▼
   Cache Lookup (intent dispatch; keyed by intentKey)
        │ miss
        ▼
   Embed → [0.23, 0.15, ..., 0.89]  (never interned)
        │
        ▼
   Vector Index Search (top 5, at or above 0.60)
        │
        ▼
   Overloads, protocol conformance, pin gate
        │
        ▼
   Tier → verification (below HIGH) → dispatch policy
        │ resolved                 └─ otherwise: needs-disambiguation / unresolved
        ▼
   dispatchById: validate arguments, call digest, execute ToolIMP
        │
        ▼
   ToolResult
```

## Key Design Decisions

### Hash-Based Embedder
The default `LocalEmbedder` uses FNV-1a hashing with trigram decomposition instead of a neural model. It always gives the same vector for the same text (the same as @smallchat/core's hash embedder), is fast, and is meant for development and testing. Production deployments can swap in a real embedding model by conforming to the `Embedder` protocol.

### In-Memory Vector Index
`MemoryVectorIndex` uses brute-force cosine similarity search, suitable for up to ~10,000 tools. For larger deployments, implement the `VectorIndex` protocol with an approximate nearest neighbor library.

### Actor-Based State
Critical state (`ToolRuntime`, `DispatchContext`, `ResolutionCache`) lives in actors rather than using manual locking. This eliminates data races at the language level while maintaining performance through the LRU cache.

### Protocol-Driven Extension
The system is designed for extension through protocols:
- `ToolIMP` / `StreamableIMP` / `InferenceIMP` — Tool implementations
- `Embedder` — Custom embedding models
- `VectorIndex` — Custom vector stores
- `Transport` — Custom transport layers
