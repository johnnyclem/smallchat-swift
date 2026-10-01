<div align="center">

# smallchat-swift

**Object-oriented inference. A native Swift tool compiler for the age of agents.**

[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![iOS 17+ (libraries)](https://img.shields.io/badge/iOS-17+_(libraries)-000000?logo=apple&logoColor=white)](#platforms)
[![Linux](https://img.shields.io/badge/Linux-Swift_6.1+-FCC624?logo=linux&logoColor=black)](#platforms)
[![MCP 2025-11-25](https://img.shields.io/badge/MCP-2025--11--25-6B4FBB)](https://modelcontextprotocol.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[Website](https://smallchat.dev) | [Documentation](https://smallchat.dev/docs) | [API Reference](https://smallchat.dev/api)

</div>

---

Your agent has 50 tools. The LLM sees all 50 in its context window every single turn — burning tokens, bloating prompts, and degrading selection accuracy. You write routing logic, maintain tool registries, and pray the model picks the right one.

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it — semantically, deterministically, in microseconds. No prompt stuffing. No selection lottery.

This is the **native Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat) — same architecture, same semantics, built for Apple platforms and Linux with Swift concurrency, actors, and the Swift type system.

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

**Table of contents:** [What's New](#whats-new-in-060) · [Quick Start](#quick-start) · [How It Works](#how-it-works) · [Streaming](#streaming) · [CLI Reference](#cli-reference) · [Architecture](#architecture) · [Security](#security) · [MCP Server](#mcp-server) · [Agent Messenger](#the-smallchat-app-agent-messenger) · [Claude Code Integration](#claude-code-integration) · [Dependencies](#dependencies) · [Ecosystem](#ecosystem) · [Development](#development)

## What's New in 0.6.0

This release adds the **App/UI layer**, matching the TypeScript 0.6.0 feature
set: apps are now first-class dispatch targets that expose HTML UI content
via `ui://` URIs through the MCP `resources/read` endpoint.

- **App/UI layer** (`SmallChatCore`, `SmallChatCompiler`, `SmallChatRuntime`, `SmallChatMCP`). `ComponentSelector` and `AppManifest`/`ComponentDefinition` describe UI components alongside tools; `AppCompiler` runs the same 4-phase PARSE → EMBED → LINK → EMIT pipeline as `ToolCompiler` to produce an `AppArtifact`; `AppRuntime` mirrors `ToolRuntime` with a never-throwing `uiDispatch(intent:args:)`; `AppResourceHandler` serves the resolved HTML over MCP.
- **`SmallChatUI`** — new SwiftUI library wrapping `WKWebView` (`AppWebView`) with a sandboxed configuration (`AppWebViewSandbox`) that enforces same-origin navigation and injects a CSP via `WKUserScript`, one `WKProcessPool` per view for process isolation.
- **GUI**: the macOS app (`SmallChatApp`) gained an Apps sidebar section that lists registered apps and previews them inline via `AppWebView`.

Since 0.6.0, `main` has also picked up:

- **`SmallChatTruth`** — truth-ledger interop with Stenographer's TB/UV v2 asserted-truth ledger at the JSONL seam: a lossless wiki JSONL codec (`TruthWiki`), the §7 consumption rules in code (active TB = ground truth, contested TB carries its disputing UVs, open UV is flagged `UNVERIFIED` and never reads as proven), corpus items + a stock `CompactionVerifier` invariant (`TruthInvariants.preserved`) that fails any compaction which drops a truth entry or strips the UNVERIFIED marker, and a proposal-only write path (`InvariantProposal`) that rejects anonymous identities.
- **`RtkTransport`** (`SmallChatTransport`) — a transport-wrapping actor that ports the TS `rtk-which` / `rtk-transport` integration: prefixes eligible shell commands with `rtk` and pipes response bodies ≥ 512 B through `rtk filter`, with metadata attached to every response for observability. Pure pass-through when disabled.
- **`DispatchConfig.miniLM`** — a threshold preset recalibrated for lower-contrast sentence embedders (e.g. `all-MiniLM-L6-v2`), where correct-tool paraphrases commonly score 0.60–0.74 and get misclassified as `.low` under the library defaults.
- **Bounded selector cache** — `SelectorTable.resolve()` no longer inserts runtime intents into the shared tool-selector vector index; they're now cached in a bounded, LRU-evicted side table so long-running processes can't dilute real tool candidates or accumulate unbounded state.
- **`LocalEmbedder`** is now byte/Float32-compatible with the TS reference implementation (UTF-16 hashing, ASCII tokenization rule, exact `ToInt32` fold), verified against golden vectors.

See [`CHANGELOG.md`](CHANGELOG.md) for the full history, including the 0.5.0
confidence-tiered dispatch, loom-mcp, and Registry/Install release
(`docs/0.5.0-roadmap.md` has the per-phase breakdown) and the earlier 0.3.0
security-hardening release.

## Quick Start

### Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
]
```

> Version tags start at `1.0.0`. Releases before 1.0 were never tagged, so an older checkout can only be pinned by `branch:` or `revision:`.

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

> Requires **Swift 6.1+**. See [Platforms](#platforms) for what builds where.

### Platforms

CI builds every "yes" cell and runs the test suite on macOS and Linux (see `.github/workflows/swift.yml`).

| Product | macOS 14+ | Linux (Swift 6.1+) | iOS 17+ |
|---|---|---|---|
| `SmallChatCore`, `SmallChatRuntime`, `SmallChatCompiler`, `SmallChatEmbedding` | yes | yes | yes |
| `SmallChatShorthand`, `SmallChatImportance`, `SmallChatCRDT`, `SmallChatCompaction`, `SmallChatTruth`, `SmallChatMemex`, `SmallChatDream` | yes | yes | yes |
| `SmallChatTransport`, `SmallChatMCP`, `SmallChatChannel` | yes | yes | yes, without subprocess APIs ¹ |
| `SmallChat` (umbrella) | yes | yes, without `SmallChatUI` ² | yes |
| `SmallChatUI` | yes | no (needs SwiftUI/WebKit) | yes |
| `SmallChatAgents` | yes | yes | no (spawns the `claude` CLI) |
| `smallchat` CLI | yes | yes | n/a |
| `SmallChatApp` (messenger) | yes | no (AppKit) | no |

¹ `MCPStdioTransport`, `LoomMCPClient` and `ContainerSandbox.spawnProcess` / `isDockerAvailable`
need `Foundation.Process`, which iOS does not have, so they are compiled only on macOS and Linux.
On iOS, `RtkTransport` passes bodies through uncompressed because the `rtk filter` subprocess cannot run.

² `SmallChatUI` and `SmallChatApp` are declared only when the manifest is evaluated on macOS.
On Linux, `import SmallChat` re-exports every other module.

On Linux, SHA-256/HMAC come from [swift-crypto](https://github.com/apple/swift-crypto) (the
same API as CryptoKit, which Apple platforms use), and streaming HTTP bodies are read through a
`URLSessionDataDelegate`, because swift-corelibs-foundation has no `URLSession.bytes(for:)`.

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
│    Cosine similarity, top-5 candidates, threshold 0.60       │
│    (tune per embedder — see DispatchConfig.miniLM)           │
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
| `setup` | Interactive wizard — auto-detect MCP servers and compile a toolkit | `smallchat setup` |
| `compile` | Compile manifests into a dispatch artifact (`--strict` treats collisions as errors) | `smallchat compile --source ~/.mcp.json` |
| `resolve` | Test intent-to-tool resolution | `smallchat resolve tools.toolkit.json "search for code"` |
| `serve` | Serve a toolkit as an MCP server over Streamable HTTP | `smallchat serve --source ./manifests --port 3001` |
| `channel` | Run a Claude Code channel server over stdio (optional HTTP bridge) | `smallchat channel --name ci` |
| `install` | Render an install plan for a registry entry or bundle | `smallchat install examples/registry/github.json` |
| `init` | Scaffold a new project from a template | `smallchat init my-app --template agent` |
| `repl` | Interactive resolution shell | `smallchat repl tools.toolkit.json` |
| `docs` | Generate Markdown documentation | `smallchat docs --artifact tools.toolkit.json -o docs.md` |
| `inspect` | Examine a compiled artifact | `smallchat inspect tools.toolkit.json` |
| `dream` | Re-compile tools from Claude session/memory insights | `smallchat dream --source ~/.claude` |
| `memex` | Knowledge-base compiler (`compile`, `query`, `lint`, `inspect`, `export`) | `smallchat memex compile notes/*.md -o kb.json` |
| `doctor` | Diagnose environment issues | `smallchat doctor` |

## Architecture

### Module Map

```
SmallChatCore          Foundation: types, selectors, dispatch tables, cache, App/UI types
       │
SmallChatRuntime       Dispatch engine, fluent API, streaming, swizzling, AppRuntime
       │
   ┌───┼───────────┬──────────────┬──────────────┬───────────┐
   │   │           │              │              │           │
Compiler  Embedding  Transport      MCP         Channel      Dream
   │       │         │              │              │           │
   │   FNV-1a hash   HTTP/SSE/     MCP Server    Claude Code  Memory-driven
   │   vector index  stdio NIO,    sessions/SQLite JSON-RPC    recompilation
   │                 rtk filter,   App resources
   │                 loom client
   │
Shorthand ── Importance / CRDT / Compaction / Memex   (text + memory primitives)
   │              └── Truth (TB/UV ledger interop rides Compaction)
   │
SmallChatUI ─── WKWebView wrapper for App/UI surfaces (sandboxed, CSP-injected)
   │
SmallChat ─── Umbrella module (re-exports everything above)
   │
SmallChatAgents ─── Agent messenger core: session discovery, handles, @mentions,
   │                 group routing, switchboard relay, stenographer (rides Truth)
   │
   ├── SmallChatCLI ─── 13 commands via swift-argument-parser
   └── SmallChatApp ─── macOS SwiftUI messenger for Claude Code sessions (+ Toolkit panels)
```

### Modules

| Module | Description |
|--------|-------------|
| **SmallChatCore** | Type system, selectors, dispatch tables, resolution cache, overload tables, canonicalization, vector math, intent pinning, rate limiting, confidence tiers (`DispatchConfig`, incl. the `miniLM` preset), App/UI types (`ComponentSelector`, `AppManifest`, `AppArtifact`) |
| **SmallChatRuntime** | `ToolRuntime` actor, dispatch pipeline, `DispatchBuilder` fluent API, streaming events, method swizzling, tiered dispatch (verify/decompose/refine), `AppRuntime` for UI dispatch |
| **SmallChatCompiler** | 4-phase compilation pipeline: parse → embed → link → output, plus `AppCompiler` for the App/UI layer |
| **SmallChatEmbedding** | `LocalEmbedder` (FNV-1a hash, 384 dims, TS-parity), `MemoryVectorIndex` for dev/test |
| **SmallChatTransport** | Protocol-agnostic transport layer — HTTP, MCP stdio, MCP SSE, local — with auth, retry, timeout, and circuit breaker middleware; `LoomMCPClient` for loom-mcp; `RtkTransport` for `rtk`-based prefixing/filtering |
| **SmallChatMCP** | MCP server over Streamable HTTP (protocol 2025-11-25 and 2025-06-18): exact tool calls through a runtime whose tools run at their providers' endpoints (`MCPToolkit`), sessions (SQLite), bearer-token auth, Host/Origin checks, rate limiting, connection cap, HMAC-chained audit log, `AppResourceHandler` for `ui://` resources; `MCPClientTransport` (Streamable HTTP client) |
| **SmallChatChannel** | Claude Code integration: JSON-RPC 2.0 over stdio, sender gating, permission relay, and the channel HTTP bridge (`ChannelBridgeServer`: `POST /event`, mandatory shared secret) used by `smallchat channel --http-bridge` and the messenger's objection channel |
| **SmallChatDream** | Memory-driven tool re-compilation: reads Claude session/memory logs to discover tool usage and recompile toolkits |
| **SmallChatShorthand** | Text primitives shared by the modules below — tokenization, Jaccard/cosine similarity, FNV-1a content hashing |
| **SmallChatImportance** | Three-signal importance detector (recency decay, co-mention centrality, novelty) with weighted ranking |
| **SmallChatCRDT** | Conflict-free replicated types for multi-agent shared memory: `LWWMap`, `ORSet`, `GCounter`, `VectorClock` |
| **SmallChatCompaction** | `CompactionVerifier` — three-strategy verification (resampling, contradiction detection, invariants) for safe history compaction |
| **SmallChatTruth** | Truth-ledger interop (Stenographer TB/UV v2): wiki JSONL codec, §7 consumption rules, truth-preserving compaction invariants, proposal-only write path |
| **SmallChatAgents** | Agent messenger core: Claude Code session discovery (live registry + transcripts), durable renamable handles, `@mention` parsing, direct/group routing with private-until-shared replies, the switchboard relay over Claude Code inter-agent messaging, headless `claude -p --resume`, and the stenographer watcher |
| **SmallChatMemex** | Knowledge-base compiler: the same Read → Extract → Embed → Link → Emit pipeline as `ToolCompiler`, driving `smallchat memex` |
| **SmallChatUI** | SwiftUI `WKWebView` wrapper (`AppWebView`) for rendering App/UI content, with sandboxed navigation and CSP injection |
| **SmallChat** | Umbrella module — imports and re-exports all of the above |
| **SmallChatApp** | macOS SwiftUI messenger for Claude Code sessions (direct + group chats, `@mentions`, stenographer), with the Compiler, Server, Manifest editor, Inspector, Resolver, Discovery, Apps, and Doctor panels under Toolkit |

## Security

smallchat is designed to run in adversarial environments where untrusted inputs flow through the dispatch pipeline. v0.3.0 includes multiple hardening layers:

| Feature | Protection |
|---------|------------|
| **Intent Sanitization** | Strips null bytes, control characters, and enforces length limits before dispatch (v0.3.0). |
| **Intent Pinning** | Guards sensitive selectors (e.g., `delete:database`) against semantic collision attacks. Supports `exact` (canonical match only) and `elevated` (0.98 threshold) policies. |
| **Type Validation** | Validates argument types against method signatures before dispatch, preventing type confusion attacks. |
| **Sender Gating** | Allowlist-based access control with identity validation, max sender limits, and constant-time pairing code verification (v0.3.0). |
| **Semantic Rate Limiting** | Prevents vector flooding DoS by tracking embedding requests per time window. |
| **Bounded Selector Cache** | Runtime intents resolved by `SelectorTable` are kept in an LRU-evicted side table, not the shared tool-selector index — long-running processes can't accumulate unbounded state or dilute real tool candidates. |
| **Selector Namespacing** | Core system selectors are protected and cannot be shadowed by user-registered tools. |
| **Bearer Token** | With `serve --auth`, every MCP request (all but `GET /health`) needs `Authorization: Bearer <token>`, compared in constant time. The token comes from `SMALLCHAT_MCP_TOKEN` or a file created with mode 0600. OAuth is not implemented. |
| **Schema Fingerprinting** | Detects tool schema changes on hot-reload; invalidates stale cache entries automatically. |
| **Structured Concurrency** | Actor-based isolation and `Sendable` conformance enforced at compile time. No raw threads. |
| **Audit Log Integrity** | HMAC-SHA256 chain over every field of each entry, under a secret key (random per server unless you pass one; there is no built-in key). It detects edits to retained entries by anyone without the key, and still verifies after old entries are evicted. In memory only: it does not survive a restart. |
| **Connection Limits** | The MCP server closes connections beyond `maxConnections` and rejects bodies over `maxRequestBodyBytes` (413). |
| **DNS-Rebinding Protection** | A loopback-bound MCP server rejects non-loopback `Host` names and foreign `Origin`s (403). |

## MCP Server

`smallchat serve` serves a toolkit as an MCP server over Streamable HTTP (protocol
versions 2025-11-25 and 2025-06-18, negotiated in `initialize`):

```bash
swift run smallchat serve --source ./manifests --port 3001
```

- **Exact tool calls.** Tools are listed as `<provider>__<tool>` (with `--provider <id>`,
  one provider's tools under their upstream names), and `tools/call` runs exactly the
  named tool. An unknown name is a JSON-RPC error; nothing is resolved fuzzily. Results
  are MCP `CallToolResult`s (`content`, `structuredContent` for JSON objects, `isError`).
- **Where tools run.** A tool runs at its provider manifest's `endpoint`: MCP servers over
  Streamable HTTP (the upstream result is passed through), REST APIs as
  `POST <endpoint>/<tool>`. Tools whose provider has no such endpoint are listed but return
  `isError` when called. Artifacts compiled before 1.0 carry no endpoints.
- **Semantic dispatch is opt-in.** `--semantic-dispatch` adds the `smallchat_dispatch`
  meta-tool, which resolves an intent through the tiered dispatch pipeline.
- **Sessions** in SQLite (`--db-path`), expiring after `--session-ttl` hours.
- **Perimeter:** Host/Origin checks, optional bearer token (`--auth`), body size cap,
  per-address rate limiting (`--rate-limit`), connection cap (`--max-connections`), and an
  in-memory HMAC-chained audit log (`--audit`).

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/mcp` | One JSON-RPC message (`initialize` opens a session; send its `Mcp-Session-Id` afterwards). Notifications get `202`. Batches are rejected. |
| `DELETE` | `/mcp` | End the session named by `Mcp-Session-Id` |
| `GET` | `/mcp` | `405`: the server opens no server-to-client stream |
| `GET` | `/health` | Status, tool counts, protocol versions (no auth) |
| `GET` | `/metrics` | Request and connection counters |

Not implemented: server-to-client SSE streams (so no `list_changed` or resource
subscription notifications), JSON-RPC batches, MCP logging, and OAuth. Adopting the
official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) is planned
for a 1.x release.

## The smallchat App: Agent Messenger

`swift run SmallChatApp` opens a macOS messenger for your Claude Code sessions.

- **Every session, on the left.** Live sessions (with busy/idle status and interactive/background kind) are read from Claude Code's session registry, and recent stopped ones from their transcripts under `~/.claude/projects`. Archive a session to hide it.
- **Durable names.** Each session gets a human-readable handle like `@instrument-62`. You can rename it; the name persists across launches and is what you `@mention`.
- **Chat.** Click a session to open a direct chat. A live session receives the message through Claude Code's inter-agent messaging, arriving between tool calls or starting a new turn if it's idle. A stopped session is resumed headlessly for one turn (`claude -p --resume`), one turn at a time; a running session is never resumed.
- **Group chats.** Put yourself and one or more agents in a group. Anything you send goes to every agent, unless you `@mention` specific ones (`@all` sends to everyone). Each agent's reply comes **only to you**. **Share with group** forwards it to the other agents as an interrupt; **Keep private** keeps it to yourself.
- **@stenographer.** A stenographer watches every chat. It is preloaded with the tombstones (TB) and unverified claims (UV) from your project wiki's truth ledger, which is Stenographer's `export_wiki_entries` JSONL. It objects when a message asserts a tombstoned value, and flags when a message relies on an unverified claim. Its notes are visible only to you. Ask it questions directly with `@stenographer`: a headless session answers with the ledger in its system prompt and only `Read`, `Grep` and `Glob` for tools, so it can read the chat's working directory and nothing else (no shell, web, MCP servers or messaging).
- **Live tool activity.** Each live session's card streams what it's doing, read from the tail of its transcript: the tool in flight (`Bash · Build the app`), the last few finished steps (✓/✗), or its latest line of prose.
- **Objection channel.** The app runs the loopback bridge Stenographer's `--objection-channel` posts to (`POST /event`, `X-Channel-Secret`), the same contract as smallchat's TS channel bridge. Each real-time objection lands in the offending agent's chats and, by default, is relayed into its live session as an interrupt so it can correct course. **Settings → Objection channel** has the port, the secret, and a copyable Stenographer command:
  ```bash
  SMALLCHAT_CHANNEL_SECRET=<secret> npx stenographer start <log-or-dir> \
    --objections deliver --objection-channel http://127.0.0.1:7337
  ```
- **Tombstones with literals.** Sign a tombstone from the Stenographer page, or from any chat message with **Tombstone a Value…**. You give the claim, the evidence, and the literals (subject / dead value / current value) that objections can cite. It's appended to your wiki JSONL as a signed TB, and the in-app stenographer starts objecting to those values immediately. Stenographer proper picks it up through `import_wiki_entries`. Literals follow Stenographer's rule: a bare value like `30` needs a subject, which it validates on import too.
- The original compiler/server/inspector panels live under **Toolkit** in the sidebar.

**How delivery to a live session works.** Claude Code delivers into a running session only through its own cross-session messaging (`SendMessage`), and the inbox socket's wire format isn't a public contract. So the app keeps one small headless session, the *switchboard* (named `smallchat`). It is launched with `--tools SendMessage,ListAgents`, so those are the only tools it has whatever your settings pre-approve, with no MCP servers (`--strict-mcp-config`), and in an empty directory of its own. It relays your messages verbatim, agents reply to it by name, and it passes those replies back to the app. Commands and replies are framed with a random per-switchboard nonce, so text inside a message can't pose as a reply from another agent, a delivery receipt or a new relay command; the switchboard is still a model, so this does not make it immune to instructions inside the messages it relays. The receiving session's own inbound controls still apply: a session running with `bypassPermissions` holds messages for your approval (see Claude Code's `crossSessionInbound` setting). Everything except the SwiftUI views lives in the `SmallChatAgents` library and is unit-tested.

## Claude Code Integration

smallchat ships with first-class support for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via a dedicated channel server:

```bash
swift run smallchat channel --name ci
# with the HTTP bridge, so webhooks (or stenographer's --objection-channel) can post events:
SMALLCHAT_CHANNEL_SECRET=... swift run smallchat channel --name ci --http-bridge --http-bridge-port 3002
```

The channel uses **JSON-RPC 2.0 over stdio** and supports:
- **Bidirectional messaging** — Claude Code can invoke tools; tools can reply back
- **Sender gating** — Allowlist-based access control with a secure pairing flow
- **Permission relay** — Two-way channel for requesting and granting permissions
- **MCP handshake** — `initialize` negotiates 2025-11-25, 2025-06-18 or 2024-11-05
- **HTTP bridge** (`--http-bridge`) — `POST /event` (`{channel?, content, meta?, sender?}`,
  authenticated with `X-Channel-Secret` or `Authorization: Bearer`; the secret from
  `SMALLCHAT_CHANNEL_SECRET` is required) injects an event into the channel; `GET /health`
  answers liveness. Permission verdicts over HTTP (`POST /permission`) are not implemented.

The command exits when Claude Code closes its stdin.

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5.0+ | CLI command parsing |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | 0.15.0+ | Session persistence |
| [swift-nio](https://github.com/apple/swift-nio) | 2.70.0+ | HTTP/SSE async transport |
| [swift-collections](https://github.com/apple/swift-collections) | 1.1.0+ | `OrderedDictionary` for LRU cache |

No external embedding models are required. The built-in `LocalEmbedder` uses FNV-1a hash-based embeddings (384 dimensions) for development and testing. For production, provide a custom `Embedder` conformance backed by your embedding model of choice.

## Ecosystem

smallchat-swift is one of four sibling projects (AgentVault, SmallChat, Stenographer, Short-Hand)
sharing a design philosophy for autonomous agent infrastructure. See
[`docs/ecosystem/executive-summary.md`](docs/ecosystem/executive-summary.md) and
[`docs/ecosystem/engineering-guide.md`](docs/ecosystem/engineering-guide.md) for a source-verified
evaluation of how this repo fits into that stack, including a naming-collision gap between this
repo's `SmallChatShorthand` module and the unrelated sibling "Short-Hand" project.

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

The same commands work on Linux, where the manifest leaves out the SwiftUI targets.
CI runs them on macOS (Xcode 16.4 and the newest Xcode) and in `swift:6.1`,
`swift:6.3` and `swift:6.4` Linux containers, and builds the `SmallChat` scheme for iOS.

### Project Structure

```
smallchat-swift/
├── Package.swift
├── Sources/
│   ├── SmallChat/                  # Umbrella module
│   ├── SmallChatCore/              # Foundation (types, selectors, dispatch tables, App/UI types)
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
│   ├── SmallChatRuntime/           # Dispatch engine (ToolRuntime, AppRuntime, DispatchBuilder)
│   ├── SmallChatCompiler/          # 4-phase compiler (tools + apps)
│   ├── SmallChatEmbedding/         # Hash-based embeddings
│   ├── SmallChatTransport/         # Network transports + middleware (incl. RTK/, Loom/)
│   ├── SmallChatMCP/               # MCP server implementation
│   ├── SmallChatChannel/           # Claude Code channel
│   ├── SmallChatDream/             # Memory-driven tool re-compilation
│   ├── SmallChatShorthand/         # Text primitives
│   ├── SmallChatImportance/        # Three-signal importance detection
│   ├── SmallChatCRDT/              # Multi-agent shared memory (LWWMap, ORSet, GCounter)
│   ├── SmallChatCompaction/        # History-compaction verification
│   ├── SmallChatMemex/             # Knowledge-base compiler
│   ├── SmallChatAgents/            # Agent messenger core (sessions, handles, routing, switchboard)
│   ├── SmallChatUI/                # WKWebView wrapper for App/UI surfaces
│   ├── SmallChatCLI/               # CLI entry point + 13 commands (Commands/)
│   └── SmallChatApp/               # macOS SwiftUI messenger (Messenger/) + Toolkit panels (Views/)
├── Tests/                          # One *Tests target per module above
├── examples/                       # loom-mcp manifest, registry entries (GitHub, Slack, Postgres, loom)
├── docs/                           # Ecosystem positioning + 0.5.0 roadmap
└── docs-site/                      # Docusaurus documentation site
```

## License

[MIT](LICENSE)

---

<div align="center">

Built with Swift. Inspired by Smalltalk.

[smallchat.dev](https://smallchat.dev)

</div>
