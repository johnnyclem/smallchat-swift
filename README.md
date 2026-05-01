<div align="center">

# smallchat-swift

**Object-oriented inference. A native Swift tool compiler for the age of agents.**

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![iOS 17+](https://img.shields.io/badge/iOS-17+-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![MCP 2024-11-05](https://img.shields.io/badge/MCP-2024--11--05-6B4FBB)](https://modelcontextprotocol.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[Website](https://smallchat.dev) | [Documentation](https://smallchat.dev/docs) | [API Reference](https://smallchat.dev/api)

</div>

---

Your agent has 50 tools. The LLM sees all 50 in its context window every single turn — burning tokens, bloating prompts, and degrading selection accuracy. You write routing logic, maintain tool registries, and pray the model picks the right one.

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it — semantically, deterministically, in microseconds. No prompt stuffing. No selection lottery.

This is the **native Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat) — same architecture, same semantics, built for Apple platforms with Swift concurrency, actors, and the Swift type system.

```
                         ┌─────────────────────┐
  "find recent docs"  →  │  Canonicalize        │  → "find:recent:docs"
                         │  Embed (384-dim)     │  → [0.23, 0.15, ..., 0.89]
                         │  Vector Search       │  → cosine similarity > 0.60
                         │  Tier classification │  → EXACT / HIGH / MEDIUM / LOW / NONE
                         │  Overload Resolution │  → type-validated dispatch
                         │  Cache & Execute     │  → result (or tool_refinement_needed)
                         └─────────────────────┘
```

## What's New in 0.5.0

This release closes the gap to the TypeScript main branch and adds the
loom-mcp integration as a first-class compile target.

- **Confidence-tiered dispatch** (TS PR #54). Every dispatch now returns
  one of `EXACT / HIGH / MEDIUM / LOW / NONE`. MEDIUM triggers pre-flight
  verification, LOW decomposes into sub-intents, and NONE returns a
  structured `tool_refinement_needed` payload with a replayable proof
  trace. The default vector-search threshold drops from 0.75 to 0.60;
  tier classification handles the additional noise.
- **loom-mcp as a compile target** (TS PR #61). The bundled
  `examples/loom-mcp-manifest.json` advertises 28 loom tools with
  `selectorHint`s and aliases; the compiler folds them into the embedder
  input so phrases like "find callers of foo" route to
  `loom_find_importers`. A typed `LoomMCPClient` wraps the existing
  stdio transport for runtime use.
- **Registry / Bundle / Install schemas** (TS PR #52). New types in
  `SmallChatCore` describe the distribution layer: `RegistryEntry`,
  `RegistryIndex`, `SmallChatBundle`, `InstallPlan`.
  `smallchat install <path>` renders an `InstallPlan` (dry-run only).
  Examples for GitHub, Slack, PostgreSQL, and loom under
  `examples/registry/`.
- **Five new modules** ported from TS PRs #55–#58, #60:
  `SmallChatShorthand` (text primitives), `SmallChatImportance`
  (three-signal detector), `SmallChatCRDT` (LWWMap, ORSet, GCounter,
  VectorClock), `SmallChatCompaction` (three-strategy verification),
  `SmallChatMemex` (knowledge-base compiler with the same
  Read → Extract → Embed → Link → Emit pipeline as `ToolCompiler`).
- **`smallchat memex`** — a new CLI suite (`compile`, `query`, `lint`,
  `inspect`, `export`) that mirrors the TS Memex surface.
- **`--strict`** on `smallchat compile` raises dedup / collision
  thresholds and treats collisions as compile errors (exit code 2).
- **GUI surfaces**: tier badges, refinement panel, loom-mcp status in
  Discovery, on top of the macOS SwiftUI app added in 0.3.0.
- Version reporting bumped to 0.5.0 across CLI commands, the MCP server,
  and the compiled artifact format.

See `docs/0.5.0-roadmap.md` for the per-phase breakdown and
`CHANGELOG.md` for the cumulative diff against 0.3.0.

## Quick Start

### Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "0.5.0"),
]
```

Then add the module you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SmallChat", package: "smallchat-swift"),  // Everything
        // Or pick individual modules:
        // .product(name: "SmallChatRuntime", package: "smallchat-swift"),
        // .product(name: "SmallChatMCP", package: "smallchat-swift"),
    ]
),
```

> Requires **Swift 6.0+**, **macOS 14+** (Sonoma), or **iOS 17+**

### Compile Your Tools

```bash
# Point it at your MCP config, a directory of manifests, or any MCP server
swift run smallchat compile --source ~/.mcp.json
```

One command. Out comes a compiled artifact with embedded vectors, dispatch tables, and resolution caching — ready to serve.

### Use the Runtime

```swift
import SmallChat

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

// Direct dispatch
let result = try await runtime.dispatch("find flights", args: ["to": "NYC"])

// Fluent API
let content = try await runtime
    .dispatch()
    .intent("find flights")
    .withArgs(["to": "NYC"])
    .exec()
```

## How It Works

smallchat borrows its architecture from the **Smalltalk / Objective-C runtime**. Tools are objects. Intents are messages. Dispatch is semantic.

The LLM says *what* it wants. The runtime figures out *which tool* handles it — using vector similarity, resolution caching, superclass traversal, and fallback chains. No routing code. No tool selection prompts.

### The Dispatch Pipeline

```
User Intent (natural language string)
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Canonicalize                                              │
│    Strip stopwords, lowercase, tokenize                      │
│    "find my recent documents" → "find:recent:documents"      │
├──────────────────────────────────────────────────────────────┤
│ 2. Embed                                                     │
│    FNV-1a hash → 384-dimensional vector (dev/test)           │
│    Pluggable for production semantic embeddings              │
├──────────────────────────────────────────────────────────────┤
│ 3. Intent Pin Check (fast path)                              │
│    Exact match for pinned/sensitive selectors                │
├──────────────────────────────────────────────────────────────┤
│ 4. Cache Lookup (LRU)                                        │
│    O(1) hit for previously resolved intents                  │
├──────────────────────────────────────────────────────────────┤
│ 5. Vector Search                                             │
│    Cosine similarity, top-5 candidates, threshold 0.75       │
├──────────────────────────────────────────────────────────────┤
│ 6. Overload Resolution                                       │
│    Type-validated signature matching against arguments       │
├──────────────────────────────────────────────────────────────┤
│ 7. Dispatch Table Resolve                                    │
│    Walk ISA chain (superclass → protocol → forwarding)       │
├──────────────────────────────────────────────────────────────┤
│ 8. Execute & Stream                                          │
│    Token-level → chunk-level → single-shot response tiers    │
└──────────────────────────────────────────────────────────────┘
```

### Runtime Concepts

smallchat maps Objective-C runtime concepts directly into the tool dispatch domain:

| Objective-C / Smalltalk | smallchat-swift | Purpose |
|-------------------------|-----------------|---------|
| Class | `ToolClass` | Groups related tools from one provider |
| Selector (`SEL`) | `ToolSelector` | Semantic intent with embedded vector |
| IMP (function pointer) | `ToolIMP` protocol | Abstract tool implementation |
| `objc_msgSend` | `Dispatch.resolveToolIMP()` | Core resolution + execution |
| Method cache | `ResolutionCache` | LRU cache with version tracking |
| ISA chain | Superclass traversal | Fallback resolution through class hierarchy |
| Protocol conformance | `ToolClass.protocols` | Capability-based dispatch |
| Category | Provider extensions | Dynamic method injection |
| Method swizzling | `runtime.swizzle()` | Hot-swap implementations at runtime |

## Streaming

smallchat supports three tiers of streaming output, all built on Swift's `AsyncSequence`:

```swift
// Token-by-token streaming (inference)
for try await token in runtime.inferenceStream("find flights", args: ["to": "NYC"]) {
    print(token, terminator: "")
}

// Rich event stream (full dispatch lifecycle)
for try await event in runtime.dispatchStream("find flights") {
    switch event {
    case .resolving(let intent):
        print("Resolving: \(intent)")
    case .toolStart(let toolName, let providerId, let confidence, _):
        print("→ \(toolName) from \(providerId) (confidence: \(confidence))")
    case .inferenceDelta(let delta, _):
        print(delta.text, terminator: "")
    case .chunk(let content, _):
        print("[chunk]: \(content)")
    case .done(let result):
        print("Done: \(result)")
    case .error(let message, _):
        print("Error: \(message)")
    }
}
```

## CLI Reference

```bash
swift run smallchat <command> [options]
```

| Command | Description | Example |
|---------|-------------|---------|
| `compile` | Compile manifests into a dispatch artifact | `smallchat compile --source ~/.mcp.json` |
| `resolve` | Test intent-to-tool resolution | `smallchat resolve tools.toolkit.json "search for code"` |
| `serve` | Start an MCP-compatible HTTP server | `smallchat serve --source ./manifests --port 3001` |
| `channel` | Start a Claude Code channel server | `smallchat channel --port 3002` |
| `init` | Scaffold a new project from a template | `smallchat init my-app --template agent` |
| `repl` | Interactive resolution shell | `smallchat repl tools.toolkit.json` |
| `docs` | Generate Markdown documentation | `smallchat docs --artifact tools.toolkit.json -o docs.md` |
| `inspect` | Examine a compiled artifact | `smallchat inspect tools.toolkit.json` |
| `doctor` | Diagnose environment issues | `smallchat doctor` |

## Architecture

### Module Map

```
SmallChatCore          Foundation: types, selectors, dispatch tables, cache
       │
SmallChatRuntime       Dispatch engine, fluent API, streaming, swizzling
       │
   ┌───┼───────────┬──────────────┬──────────────┐
   │   │           │              │              │
Compiler  Embedding  Transport      MCP         Channel
   │       │         │              │              │
   │   FNV-1a hash   HTTP/SSE/     MCP Server    Claude Code
   │   vector index  stdio NIO     OAuth/SQLite   JSON-RPC
   │
SmallChat ─── Umbrella module (re-exports everything)
   │
SmallChatCLI ─── 9 commands via swift-argument-parser
```

### Modules

| Module | Description |
|--------|-------------|
| **SmallChatCore** | Type system, selectors, dispatch tables, resolution cache, overload tables, canonicalization, vector math, intent pinning, rate limiting |
| **SmallChatRuntime** | `ToolRuntime` actor, dispatch pipeline, `DispatchBuilder` fluent API, streaming events, method swizzling |
| **SmallChatCompiler** | 4-phase compilation pipeline: parse → embed → link → output |
| **SmallChatEmbedding** | `LocalEmbedder` (FNV-1a hash, 384 dims), `MemoryVectorIndex` for dev/test |
| **SmallChatTransport** | Protocol-agnostic transport layer — HTTP, MCP stdio, MCP SSE, local — with auth, retry, timeout, and circuit breaker middleware |
| **SmallChatMCP** | Full MCP 2024-11-05 server: routing, sessions (SQLite), OAuth 2.1, rate limiting, audit logging, SSE broker |
| **SmallChatChannel** | Claude Code integration: JSON-RPC 2.0 over stdio, sender gating, permission relay |
| **SmallChat** | Umbrella module — imports and re-exports all of the above |

## Security

smallchat is designed to run in adversarial environments where untrusted inputs flow through the dispatch pipeline. v0.3.0 includes multiple hardening layers:

| Feature | Protection |
|---------|------------|
| **Intent Sanitization** | Strips null bytes, control characters, and enforces length limits before dispatch (v0.3.0). |
| **Intent Pinning** | Guards sensitive selectors (e.g., `delete:database`) against semantic collision attacks. Supports `exact` (canonical match only) and `elevated` (0.98 threshold) policies. |
| **Type Validation** | Validates argument types against method signatures before dispatch, preventing type confusion attacks. |
| **Sender Gating** | Allowlist-based access control with identity validation, max sender limits, and constant-time pairing code verification (v0.3.0). |
| **Semantic Rate Limiting** | Prevents vector flooding DoS by tracking embedding requests per time window. |
| **Selector Namespacing** | Core system selectors are protected and cannot be shadowed by user-registered tools. |
| **OAuth 2.1 Token Security** | Tokens hashed with PBKDF2 — never stored in plain text. |
| **Schema Fingerprinting** | Detects tool schema changes on hot-reload; invalidates stale cache entries automatically. |
| **Structured Concurrency** | Actor-based isolation and `Sendable` conformance enforced at compile time. No raw threads. |
| **Audit Log Integrity** | HMAC-SHA256 hash chain on audit entries for tamper detection (v0.3.0). |
| **Connection Limits** | Configurable max concurrent connections and request body size limits on MCP server (v0.3.0). |
| **TLS Configuration** | Certificate pinning, minimum TLS version enforcement, and secure transport defaults (v0.3.0). |

## MCP Server

smallchat includes a production-grade **Model Context Protocol** server (spec version 2024-11-05):

```bash
swift run smallchat serve --source ./manifests --port 3001
```

**Capabilities:**
- Tool invocation with dispatch-table resolution
- Resource and prompt registries
- SSE streaming for real-time events
- Session management with SQLite persistence
- OAuth 2.1 authentication with secure token hashing
- Per-client rate limiting with automatic stale-entry eviction
- Full audit logging (timestamp, sender, tool, args, result)
- Configurable CORS origins

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/mcp/initialize` | Initialize a session |
| `GET` | `/mcp/resources` | List available resources |
| `GET` | `/mcp/prompts` | List available prompts |
| `POST` | `/mcp/invoke` | Invoke a tool |
| `GET` | `/mcp/events` | SSE event stream |

## Claude Code Integration

smallchat ships with first-class support for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via a dedicated channel server:

```bash
swift run smallchat channel --port 3002
```

The channel uses **JSON-RPC 2.0 over stdio** and supports:
- **Bidirectional messaging** — Claude Code can invoke tools; tools can reply back
- **Sender gating** — Allowlist-based access control with a secure pairing flow
- **Permission relay** — Two-way channel for requesting and granting permissions
- **MCP handshake** — Standard `initialize` flow for capability negotiation

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5.0+ | CLI command parsing |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | 0.15.0+ | Session persistence |
| [swift-nio](https://github.com/apple/swift-nio) | 2.70.0+ | HTTP/SSE async transport |
| [swift-collections](https://github.com/apple/swift-collections) | 1.1.0+ | `OrderedDictionary` for LRU cache |

No external embedding models are required. The built-in `LocalEmbedder` uses FNV-1a hash-based embeddings (384 dimensions) for development and testing. For production, provide a custom `Embedder` conformance backed by your embedding model of choice.

## Development

```bash
# Build
swift build                              # Debug build
swift build --release                    # Optimized release build

# Test
swift test                               # Run full test suite
swift test --filter "CanonicalizeTests"  # Run a specific test suite

# Run
swift run smallchat                      # Show CLI help
swift run smallchat doctor               # Diagnose your environment
```

### Project Structure

```
smallchat-swift/
├── Package.swift
├── Sources/
│   ├── SmallChat/                  # Umbrella module
│   ├── SmallChatCore/              # Foundation (~40 source files)
│   │   ├── Types/                  # Core data types
│   │   ├── TypeSystem/             # Type matching & validation
│   │   ├── SCObject/               # Object serialization
│   │   ├── ToolClass.swift         # Tool provider class
│   │   ├── SelectorTable.swift     # Selector → IMP mapping
│   │   ├── ResolutionCache.swift   # LRU resolution cache
│   │   ├── OverloadTable.swift     # Method overloading
│   │   ├── IntentPinRegistry.swift # Collision attack guards
│   │   ├── VectorMath.swift        # Cosine similarity (Accelerate)
│   │   └── Canonicalize.swift      # Intent normalization
│   ├── SmallChatRuntime/           # Dispatch engine
│   │   ├── ToolRuntime.swift       # Main actor
│   │   ├── Dispatch.swift          # Resolution + execution
│   │   └── DispatchBuilder.swift   # Fluent API
│   ├── SmallChatCompiler/          # 4-phase compiler
│   ├── SmallChatEmbedding/         # Hash-based embeddings
│   ├── SmallChatTransport/         # Network transports + middleware
│   ├── SmallChatMCP/               # MCP server implementation
│   ├── SmallChatChannel/           # Claude Code channel
│   └── SmallChatCLI/               # CLI entry point + commands
├── Tests/
│   ├── SmallChatCoreTests/         # Canonicalization, cache, namespacing,
│   │                               # rate limiting, overloads, pinning, types
│   ├── SmallChatChannelTests/      # Sender gate tests
│   ├── SmallChatRuntimeTests/
│   ├── SmallChatCompilerTests/
│   ├── SmallChatTransportTests/
│   ├── SmallChatMCPTests/
│   └── SmallChatEmbeddingTests/
└── docs-site/                      # Docusaurus documentation site
```

## What's New in 0.3.0

- **Intent sanitization** — Null byte stripping, control character removal, length limits, and token cap on canonical selectors
- **Audit log integrity** — HMAC-SHA256 hash chain on audit entries with tamper verification via `verifyChain()`
- **Server hardening** — Configurable max connections (default 1000), max request body size (default 1MB), graceful shutdown with drain timeout
- **Server metrics** — New `/metrics` endpoint and `ServerMetrics` actor tracking request counts, error rates, active/peak connections, uptime
- **TLS configuration** — `TLSConfig` with certificate pinning (public key or full cert), minimum TLS version enforcement, development/production presets
- **Identity validation** — Sender identities validated for format (alphanumeric + `._@-`), length (1–128 chars), and max sender limits
- **Constant-time pairing** — Pairing code verification uses constant-time comparison to prevent timing attacks
- **Connection metrics** — NIO handler tracks connection open/close for real-time connection monitoring
- **Version bump** — MCP server, channel server, and router all report version 0.3.0

### Previous: 0.2.0

- **Claude Code channel protocol** — Bidirectional stdio JSON-RPC integration with Claude Code
- **Security hardening** — Intent pinning, selector namespacing, semantic rate limiting, sender-gated permissions
- **Actor-based concurrency** — Thread-safe dispatch, caching, and session management via Swift actors
- **SQLite session persistence** — Durable session storage for MCP server connections
- **Fluent dispatch API** — Chainable `.dispatch().intent().withArgs().exec()` with Swift type inference
- **NIO-based transport** — High-performance HTTP, SSE, and stdio transports built on SwiftNIO
- **OAuth 2.1 security** — PBKDF2-hashed tokens, secure generation, proper verification
- **New CLI commands** — `init`, `docs`, `repl`, `doctor` for scaffolding, documentation, and diagnostics

## License

[MIT](LICENSE)

---

<div align="center">

Built with Swift. Inspired by Smalltalk.

[smallchat.dev](https://smallchat.dev)

</div>
