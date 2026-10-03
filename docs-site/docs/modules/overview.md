---
sidebar_position: 1
title: Module Overview
---

# Module Overview

smallchat-swift is organized into 16 library modules, the `smallchat` CLI and the macOS
`SmallChatApp`, with clear dependency boundaries. Import `SmallChat` for every library
module (all but `SmallChatAgents`), or pick individual modules for a smaller footprint.

## Module Map

```
SmallChat (umbrella: every library below except SmallChatAgents)
│
├── SmallChatCore              → swift-collections (+ swift-crypto on Linux)
│   ├── Types/                 ToolSelector, ToolIMP, ToolResult, DispatchEvent, ToolAnnotations
│   ├── Artifact/              ArtifactV1 (format 1.0): read, validate, build, write
│   ├── JSON/                  Canonical JSON (RFC 8785), JSONSchemaValidator
│   ├── Digest/                Call digests, SHA-256
│   ├── SCObject/              Objective-C-style object system
│   ├── ToolClass              Dispatch tables, overloads, ISA chain
│   ├── ToolId                 Canonical tool ids (<providerId>/<toolName>)
│   ├── Canonicalize           Display canonical, intentKey, normalizePinPhrase
│   ├── ResolutionCache        LRU cache, version-aware
│   ├── SelectorTable          Compiled tool selectors
│   ├── OverloadTable          Overload resolution by argument types
│   ├── SelectorNamespace      Core selector protection
│   ├── IntentPinRegistry      Semantic collision prevention
│   ├── SemanticRateLimiter    Opt-in, per-principal flood limiting
│   └── VectorMath             Cosine similarity (Accelerate on Apple, scalar elsewhere)
│
├── SmallChatRuntime           → Core
│   ├── ToolRuntime            Top-level runtime actor
│   ├── Dispatch               resolve, dispatchById, intent dispatch, streaming
│   ├── Policy                 evaluateDispatchPolicy
│   ├── Verification           Schema, keyword and LLM verification
│   ├── Decomposition          Sub-intents (needs an LLMClient)
│   ├── Refinement             ToolRefinement payloads
│   ├── DispatchContext        Runtime environment
│   ├── DispatchBuilder        Fluent API
│   └── AppRuntime             UI dispatch for App/UI components
│
├── SmallChatCompiler          → Core
│   ├── ToolCompiler           4-phase pipeline (duplicates and selector conflicts are errors)
│   ├── Parser                 Manifest parsing
│   ├── SemanticGrouping       Overload detection
│   ├── CompilerOptions        Configuration
│   └── AppCompiler            App/UI components
│
├── SmallChatEmbedding         → Core
│   ├── LocalEmbedder          FNV-1a + trigram hash embedder (fingerprint hash/smallchat-hash-v1)
│   └── MemoryVectorIndex      Brute-force cosine search
│
├── SmallChatTransport         → Core, NIO
│   ├── Protocols/Transport    Universal transport interface
│   ├── Implementations/       HTTP, MCP stdio, MCP SSE, Local
│   ├── Middleware/            Retry, CircuitBreaker, Timeout
│   ├── Auth/                  Bearer, OAuth2 client credentials (outbound requests)
│   ├── Streaming/             SSE, NDJSON parsers
│   ├── RTK/, Loom/            rtk filtering, loom-mcp client
│   └── Importers              OpenAPI, Postman
│
├── SmallChatMCP               → Core, Runtime, Transport, Compiler, Embedding, SQLite, NIO
│   ├── MCPServer              Streamable HTTP server (NIO), endpoint /mcp
│   ├── MCPRouter              JSON-RPC routing, exact tools/call, smallchat_resolve
│   ├── MCPTools               Tool catalog, CallToolResult shaping
│   ├── MCPToolkit             Manifests/artifact → runtime of endpoint-backed tools
│   ├── MCPClientTransport     Streamable HTTP client
│   ├── SessionStore           Sessions in SQLite
│   ├── RateLimiter            Sliding window per client address
│   ├── SSEBroker              Event broadcasting helper (not served)
│   ├── ResourceRegistry       MCP resources (incl. ui:// App resources)
│   ├── PromptRegistry         MCP prompts
│   ├── AuditLog               HMAC-chained request log (in memory)
│   └── JsonRPC                JSON-RPC 2.0 codec, protocol versions
│
├── SmallChatChannel           → Core, MCP, NIO
│   ├── ChannelServer          Stdio MCP channel server for Claude Code
│   ├── ChannelBridge          HTTP bridge (POST /event, shared secret)
│   ├── ChannelAdapter         Channel events and permission requests
│   ├── ChannelTypes           Message/event definitions
│   ├── SenderGate             Allowlist of event senders, pairing codes
│   └── ChannelUtils           Tag serialization and escaping, meta-key filtering
│
├── SmallChatDream             → Core, Compiler, Embedding
│   └── DreamCompiler          Recompile from Claude session/memory insights
│
├── SmallChatShorthand         → Core
│   └── Shorthand              Token/sentence primitives, Jaccard, FNV-1a hash
├── SmallChatImportance        → Core, Shorthand
│   └── ImportanceDetector     Three-signal scorer (recency, centrality, novelty)
├── SmallChatCRDT              → Core, Shorthand
│   └── VectorClock, LWWMap, ORSet, GCounter
├── SmallChatCompaction        → Core, Shorthand
│   └── CompactionVerifier     Three-strategy verifier (resampling, contradiction, invariants)
├── SmallChatTruth             → Core, Compaction
│   └── TruthFormat, TruthWiki, TruthQuorum, TruthCompaction, TruthObjections, TruthProposals
│                              Stenographer's truth format v2: read (fail closed), agent quorum, select, render
├── SmallChatMemex             → Core, Shorthand, Embedding, Importance
│   └── MemexCompiler, MemexResolver   READ → EXTRACT → LINK → EMIT knowledge bases
│
└── SmallChatUI (Apple only)   SwiftUI WKWebView wrapper for App/UI surfaces

SmallChatAgents                → Core, Truth, Channel, Transport, NIO   (macOS and Linux)
    Messenger core: session discovery, handles, routing, switchboard, stenographer,
    notary client, secret stores

SmallChatCLI (`smallchat`)     → SmallChat, ArgumentParser
    setup, compile, serve, channel, resolve, inspect, init, repl, docs, doctor,
    install, dream, memex

SmallChatApp (macOS only)      → SmallChat, SmallChatUI, SmallChatAgents
```

## Dependency Graph

```
                    SmallChatCore
             /     |       |        \          \
       Runtime  Compiler  Embedding  Transport  Shorthand ── Importance, CRDT, Compaction
          |        |         |          |                          |
          +--------+----+----+----------+                        Truth
                        |                                          |
                   SmallChatMCP (+ SQLite, NIO)                    |
                        |                                          |
                   SmallChatChannel ───────────── SmallChatAgents ─+
                        |                               |
             SmallChat umbrella ── SmallChatCLI    SmallChatApp
```

SmallChatShorthand, SmallChatImportance, SmallChatCRDT and SmallChatCompaction do not
depend on SmallChatRuntime or SmallChatMCP. They are ports of smallchat's 0.4-era modules
(TS PRs #55–#58), not of [@shorthand/core](https://github.com/johnnyclem/short-hand) 1.0,
whose versions of them differ. `LWWMap` merges are not commutative when two writes share
a timestamp and replica id: give each write of a replica its own timestamp.

## External Dependencies

| Package | Used By | Purpose |
|---------|---------|---------|
| [swift-collections](https://github.com/apple/swift-collections) | Core | `OrderedDictionary` for LRU cache |
| [swift-nio](https://github.com/apple/swift-nio) | Transport, MCP, Channel, Agents | HTTP servers and test servers |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | MCP | Session persistence |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI | Command-line parsing |
| [swift-crypto](https://github.com/apple/swift-crypto) | Core, MCP, Dream (Linux only) | SHA-256 and HMAC where CryptoKit is unavailable |

## Choosing Modules

| Use Case | Modules |
|----------|---------|
| Embed in an iOS/macOS app | `SmallChatCore`, `SmallChatRuntime`, `SmallChatEmbedding` |
| Compile tool manifests | Add `SmallChatCompiler` |
| Connect to remote tools | Add `SmallChatTransport` |
| Run an MCP server | Add `SmallChatMCP` |
| Integrate with Claude Code | Add `SmallChatChannel` |
| Read Stenographer's truth ledger | `SmallChatTruth` |
| Everything | `SmallChat` (umbrella) |
| Score items by recency, centrality, novelty | `SmallChatImportance` (+ `SmallChatShorthand`) |
| Multi-agent shared memory (replicated types) | `SmallChatCRDT` |
| Verify a compaction pass preserved semantics | `SmallChatCompaction` (+ `SmallChatShorthand`) |
| Build a knowledge base from text sources | `SmallChatMemex` (+ `SmallChatShorthand`, optionally `SmallChatEmbedding`) |
| Low-level text primitives only | `SmallChatShorthand` |

## Platform Support

"Builds" means the module compiles for that platform; CI builds every "Yes" cell and runs the
tests on macOS and Linux.

| Module | macOS 14+ | Linux (Swift 6.1+) | iOS 17+ | Notes |
|--------|-----------|--------------------|---------|-------|
| SmallChatCore | Yes | Yes | Yes | Accelerate on Apple platforms, scalar fallback elsewhere |
| SmallChatRuntime | Yes | Yes | Yes | |
| SmallChatCompiler | Yes | Yes | Yes | |
| SmallChatEmbedding | Yes | Yes | Yes | |
| SmallChatTransport | Yes | Yes | Yes | `MCPStdioTransport`, `LoomMCPClient` and container spawning are macOS/Linux only (no `Foundation.Process` on iOS) |
| SmallChatMCP | Yes | Yes | Yes | swift-crypto provides SHA-256/HMAC on Linux |
| SmallChatChannel | Yes | Yes | Yes | Claude Code itself runs on desktops |
| SmallChatShorthand | Yes | Yes | Yes | Pure Swift, no external dependencies |
| SmallChatImportance | Yes | Yes | Yes | |
| SmallChatCRDT | Yes | Yes | Yes | Pure Swift, no external dependencies |
| SmallChatCompaction | Yes | Yes | Yes | |
| SmallChatTruth | Yes | Yes | Yes | |
| SmallChatMemex | Yes | Yes | Yes | The compiler skips the EMBED stage; embed claims yourself if you need it |
| SmallChatDream | Yes | Yes | Yes | |
| SmallChatAgents | Yes | Yes | No | Spawns the `claude` CLI |
| SmallChatUI | Yes | No | Yes | SwiftUI + WebKit; declared only on Apple hosts |
| SmallChatCLI | Yes | Yes | n/a | CLI tool |
| SmallChatApp | Yes | No | No | macOS messenger (AppKit) |

## Phase 4 Heuristic Algorithms

SmallChatCompaction and SmallChatMemex use deliberately conservative heuristics in place of semantic understanding. They call no model and have no external dependencies; the public API surface is shaped so richer LLM-backed implementations can land without breaking callers.

See the [Phase 4 Algorithm Limitations guide](../guides/phase4-algorithms) for a breakdown of each heuristic, what it catches and misses, and the upgrade path to semantic implementations.
