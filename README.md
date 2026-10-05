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

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it to at most one tool, by embedding similarity, and runs that tool only when its dispatch policy allows; otherwise it asks. No prompt stuffing. No selection lottery.

This is the **Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat), for Apple platforms and Linux. Version 1.0 follows @smallchat/core 1.0's dispatch rules and artifact format; [Parity with @smallchat/core](#parity-with-smallchatcore) says exactly what is checked.

```
                         ┌──────────────────────┐
  "find recent docs"  →  │  Embed the intent     │  → its own vector (never interned)
                         │  Vector search        │  → candidates with cosine >= 0.60
                         │  Tier                 │  → EXACT .95 / HIGH .85 / MEDIUM .75 / LOW .60
                         │  Pins, verification,  │  → one dispatch policy on every path
                         │  dispatch policy      │
                         │  Validate & execute   │  → exactly one tool (or needs-disambiguation)
                         └──────────────────────┘
```

**Table of contents:** [What's New](#whats-new-in-100) · [Quick Start](#quick-start) · [How It Works](#how-it-works) · [Streaming](#streaming) · [CLI Reference](#cli-reference) · [Architecture](#architecture) · [Security](#security) · [MCP Server](#mcp-server) · [Agent Messenger](#the-smallchat-app-agent-messenger) · [Claude Code Integration](#claude-code-integration) · [Dependencies](#dependencies) · [Ecosystem](#ecosystem) · [Development](#development)

## What's New in 1.0.0

1.0.0 is a breaking release: see [`MIGRATION.md`](MIGRATION.md) for how to update from
0.6 and [`CHANGELOG.md`](CHANGELOG.md) for every change. It is unreleased until the
`1.0.0` tag is cut.

- **Resolve is separate from execute.** `resolve` proposes at most one tool and runs
  nothing; `dispatchById` runs exactly the named tool; intent `dispatch` runs a match
  only when the dispatch policy allows it. One policy covers every path that can run a
  tool: below HIGH similarity only with an LLM verifier's approval, destructive tools
  only at EXACT similarity or from a pinned phrase, and anything else comes back as
  `needs-disambiguation` with the candidates.
- **Checked inputs and pinned artifacts.** Arguments are validated against each tool's
  JSON Schema before anything runs. Artifacts are @smallchat/core's format 1.0,
  content-hashed and pinned to the embedder that produced their vectors. Every decision
  carries a `ResolutionProof` with a canonical call digest.
- **An MCP server that runs exactly the tool you call.** `smallchat serve` speaks
  Streamable HTTP (2025-11-25 and 2025-06-18) on `/mcp`, lists tools as
  `<provider>__<tool>`, runs them at their providers' endpoints, and offers the
  read-only `smallchat_resolve` meta-tool. `--auth` is a bearer token; OAuth and the
  TLS settings that nothing enforced are gone.
- **Linux and iOS.** CI builds and tests on macOS (Xcode 16.4 and the newest Xcode)
  and in Swift 6.1, 6.3 and 6.4 Linux containers, and builds the libraries for iOS.
- **An agent messenger.** On macOS, `swift run SmallChatApp` is a messenger for your
  Claude Code sessions, with a stenographer that objects when an agent asserts a
  tombstoned value. Tombstones you sign go to Stenographer as proposals that you
  notarize (see [the messenger](#the-smallchat-app-agent-messenger)).
- **`SmallChatTruth`** reads Stenographer's truth format v2 (hash-chained TB/UV streams
  with `TRANSITION` status lines), fails closed on anything unknown or unverifiable,
  and runs Stenographer's golden fixtures in `swift test`. Agents settle claims only
  together: a TB an agent signs is truth only with a quorum of two or more agent
  sessions agreeing from different angles within 15 minutes, and the reader refuses a
  line whose quorum breaks the spec's rules.
- Also since 0.6.0: `RtkTransport` (prefixes eligible shell commands with `rtk` and
  pipes large response bodies through `rtk filter`), and the `DispatchConfig.miniLM`
  threshold preset for lower-contrast sentence embedders.

### Parity with @smallchat/core

smallchat-swift 1.0 adopts @smallchat/core 1.0's dispatch semantics. What `swift test`
checks is the set of vectors in @smallchat/core's `spec/`, copied into
`Tests/Fixtures/spec` by `Scripts/sync-spec.sh` (the source commit is in `SOURCE`):

- **Call digests:** RFC 8785 canonical JSON and the domain-separated SHA-256, including
  the inputs that must be refused.
- **Tool ids:** valid and invalid canonical ids (`<providerId>/<toolName>`).
- **Ranking:** score quantization, candidate order and tier boundaries.
- **Resolve:** for each case, the outcome, decision, tier, chosen tool, candidate order
  and exclusions.
- **Artifacts:** the golden artifact loads and round-trips, every invalid artifact and
  embedder mismatch is refused, and compiling the golden manifest reproduces its
  content hash.

Outside those vectors the TypeScript runtime is the reference. Proof digests are per
runtime (the proof step texts differ). Not ported yet: argument coercion, the semantic
map (learned choices), observer feedback, the decision log, replay and explain. Nor is
the optional shortlist judge (`spec/judge`): this runtime never consults one, but it
decodes what TypeScript proofs record about one (the decision codes `judge-approved` and
`judge-declined`, the `judge` step and `ResolutionProof.judge`). The only
built-in embedder is the hash embedder (`LocalEmbedder`, the same vectors as
@smallchat/core's hash embedder), so an artifact compiled by @smallchat/core with its
default ONNX embedder needs an `Embedder` of yours that declares the same fingerprint.

## Quick Start

### Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
]
```

> Version tags start at `1.0.0`, which is tagged when the release is published; until then, pin a commit with `revision:`. Releases before 1.0 were never tagged, so they too can only be pinned by `branch:` or `revision:`.

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
| `SmallChatAgents` | yes | yes ³ | no (spawns the `claude` CLI) |
| `smallchat` CLI | yes | yes | n/a |
| `SmallChatApp` (messenger) | yes | no (AppKit) | no |

¹ `MCPStdioTransport`, `LoomMCPClient` and `ContainerSandbox.spawnProcess` / `isDockerAvailable`
need `Foundation.Process`, which iOS does not have, so they are compiled only on macOS and Linux.
On iOS, `RtkTransport` passes bodies through uncompressed because the `rtk filter` subprocess cannot run.

² `SmallChatUI` and `SmallChatApp` are declared only when the manifest is evaluated on macOS.

³ With Swift 6.1 on Linux, executables that link `SmallChatAgents` need
`-Xlinker --allow-shlib-undefined`: 6.1's `libswiftObservation.so` references a symbol
its `libswiftCore.so` does not export. Swift 6.2 and later link without it.
On Linux, `import SmallChat` re-exports every other module.

On Linux, SHA-256/HMAC come from [swift-crypto](https://github.com/apple/swift-crypto) (the
same API as CryptoKit, which Apple platforms use), and streaming HTTP bodies are read through a
`URLSessionDataDelegate`, because swift-corelibs-foundation has no `URLSession.bytes(for:)`.

### Compile Your Tools

```bash
# Point it at your MCP config, a directory of manifests, or any MCP server
swift run smallchat compile --source ~/.mcp.json
```

One command. Out comes an artifact in @smallchat/core's format 1.0: providers, tools, embedded selectors, collisions, the embedder's fingerprint and a content hash — ready to serve. Near-duplicate tools are a compile error (`--allow-duplicates` keeps them).

### Use the Runtime

```swift
import SmallChat

// Load a compiled toolkit (its embedder must match the one it was compiled with)
let toolkit = try await MCPToolkit.load(source: "tools.toolkit.json")
let runtime = toolkit.runtime

// Resolve: which tool would run? Nothing executes.
let resolution = try await runtime.resolve("find flights")
print(resolution.outcome, resolution.chosen ?? "-", resolution.tier)

// Run exactly one tool, by canonical id; arguments are validated against its inputSchema.
let result = try await runtime.dispatchById("flights/search_flights", args: ["to": "NYC"])

// Or resolve and run in one call. If resolution doesn't settle on one tool,
// nothing runs: the result is isError with metadata["outcome"] and the near matches.
let byIntent = try await runtime.dispatch("find flights", args: ["to": "NYC"])
```

Below HIGH similarity a tool runs only after an `LLMClient` verifier approves it, and
destructive tools (MCP `destructiveHint`) run by intent only at EXACT similarity or
from a pinned phrase. See [`MIGRATION.md`](MIGRATION.md#dispatch) for the rules.

## How It Works

smallchat borrows its architecture from the **Smalltalk / Objective-C runtime**. Tools are objects. Intents are messages. Dispatch is semantic.

The LLM says *what* it wants. The runtime figures out *which tool* handles it — using vector similarity, overloads and protocol conformance, under one dispatch policy — or says it can't tell and offers the nearest tools. No routing code. No tool selection prompts.

### The Dispatch Pipeline

```
User Intent (natural language string)
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Pinned phrase                                             │
│    The intent is, verbatim, a pinned phrase of a tool        │
├──────────────────────────────────────────────────────────────┤
│ 2. Cache (intent dispatch only)                              │
│    Keyed by intentKey (the whole text); re-judged on a hit   │
├──────────────────────────────────────────────────────────────┤
│ 3. Rate limit (opt-in, per principal)                        │
├──────────────────────────────────────────────────────────────┤
│ 4. Embed + vector search                                     │
│    The intent's own vector; top 5 at or above LOW (0.60)     │
│    Scores quantized to 1e-4, ties ordered by tool id         │
├──────────────────────────────────────────────────────────────┤
│ 5. Overloads, protocol conformance, pin gate                 │
├──────────────────────────────────────────────────────────────┤
│ 6. Verification                                              │
│    Below HIGH (below EXACT in strict mode); below HIGH it    │
│    needs an LLM verifier's approval                          │
├──────────────────────────────────────────────────────────────┤
│ 7. Dispatch policy                                           │
│    Pins, destructive tools only at EXACT, nothing below LOW  │
│    → resolved | needs-disambiguation | unresolved            │
├──────────────────────────────────────────────────────────────┤
│ 8. dispatchById                                              │
│    Validate arguments (JSON Schema), call digest, execute    │
│    exactly the chosen tool (or stream it)                    │
└──────────────────────────────────────────────────────────────┘
```

Every decision is recorded in a `ResolutionProof` whose `proofDigest` covers
everything but timings. The determinism property (from @smallchat/core's
`spec/ranking`): for the same artifact, embedder and runtime state (registered
classes, intent pins, resolution cache, options), resolving the same intent text
yields the same outcome, chosen tool, candidate order and `proofDigest`; intents
resolved before do not enter into it. It does not cover an LLM verifier's or
decomposer's answers, an opted-in rate limiter's window, or float differences
between platforms larger than half a score quantum (5e-5). The conformance vectors
(`swift test --filter SmallChatConformanceTests`) check outcomes, decision codes,
chosen tools, tiers and candidate order against @smallchat/core's; proof digests are per runtime, since the proof
step texts differ.

### Runtime Concepts

smallchat maps Objective-C runtime concepts directly into the tool dispatch domain:

| Objective-C / Smalltalk | smallchat-swift | Purpose |
|-------------------------|-----------------|---------|
| Class | `ToolClass` | Groups related tools from one provider |
| Selector (`SEL`) | `ToolSelector` | Semantic intent with embedded vector |
| IMP (function pointer) | `ToolIMP` protocol | Abstract tool implementation |
| `objc_msgSend` | `resolve` + `dispatchById` | Resolution (pure), then execution of exactly one tool |
| Method cache | `ResolutionCache` | LRU cache with version tracking |
| ISA chain | Superclass traversal | Method lookup for a matched selector through the class hierarchy |
| Protocol conformance | `ToolClass.protocols` | Capability-based dispatch |
| Category | Provider extensions | Dynamic method injection |
| Method swizzling | `runtime.swizzle()` | Hot-swap implementations at runtime |

## Streaming

smallchat supports three tiers of streaming output, all built on Swift's `AsyncSequence`:

```swift
// Token-by-token streaming (inference)
for try await token in await runtime.inferenceStream("find flights", args: ["to": "NYC"]) {
    print(token, terminator: "")
}

// Rich event stream (full dispatch lifecycle)
for try await event in await runtime.dispatchStream("find flights") {
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
| `resolve` | Show how an intent resolves (outcome, tool id, candidates, proof digest; nothing runs) | `smallchat resolve tools.toolkit.json "search for code"` |
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
| **SmallChatRuntime** | `ToolRuntime` actor, `resolve` / `dispatchById` / intent dispatch, the dispatch policy, verification, decomposition, refinement, `DispatchBuilder` fluent API, streaming events, method swizzling, `AppRuntime` for UI dispatch |
| **SmallChatCompiler** | 4-phase compilation pipeline: parse → embed → link → output, plus `AppCompiler` for the App/UI layer |
| **SmallChatEmbedding** | `LocalEmbedder` (FNV-1a hash, 384 dims by default; the same vectors as @smallchat/core's hash embedder), `MemoryVectorIndex` for dev/test |
| **SmallChatTransport** | Protocol-agnostic transport layer — HTTP, MCP stdio, MCP SSE, local — with auth, retry, timeout, and circuit breaker middleware; `LoomMCPClient` for loom-mcp; `RtkTransport` for `rtk`-based prefixing/filtering |
| **SmallChatMCP** | MCP server over Streamable HTTP (protocol 2025-11-25 and 2025-06-18): exact tool calls through a runtime whose tools run at their providers' endpoints (`MCPToolkit`), sessions (SQLite), bearer-token auth, Host/Origin checks, rate limiting, connection cap, HMAC-chained audit log, `AppResourceHandler` for `ui://` resources; `MCPClientTransport` (Streamable HTTP client) |
| **SmallChatChannel** | Claude Code integration: JSON-RPC 2.0 over stdio, sender gating, permission relay, and the channel HTTP bridge (`ChannelBridgeServer`: `POST /event`, mandatory shared secret) used by `smallchat channel --http-bridge` and the messenger's objection channel |
| **SmallChatDream** | Memory-driven tool re-compilation: reads Claude session/memory logs to discover tool usage and recompile toolkits |
| **SmallChatShorthand** | Text primitives shared by the modules below — tokenization, Jaccard/cosine similarity, FNV-1a content hashing. Ported from smallchat's 0.4-era internal package, not from [@shorthand/core](https://github.com/johnnyclem/short-hand) |
| **SmallChatImportance** | Three-signal importance detector (recency decay, co-mention centrality, novelty) with weighted ranking |
| **SmallChatCRDT** | Replicated types for multi-agent shared memory: `LWWMap`, `ORSet`, `GCounter`, `VectorClock`. `LWWMap` merges are not commutative when two writes share a timestamp and replica (see the CHANGELOG's known issues) |
| **SmallChatCompaction** | `CompactionVerifier` — three-strategy verification (resampling, contradiction detection, invariants) for safe history compaction |
| **SmallChatTruth** | Truth format v2 reader (Stenographer's truth streams): hash-chain checks, TRANSITION fold, multi-file merge, fail-closed statuses, evidence classes and the agent quorum, §7 consumption rules, marker escaping, truth-preserving compaction invariants, proposal-only write path |
| **SmallChatAgents** | Agent messenger core: Claude Code session discovery (live registry + transcripts), durable renamable handles, `@mention` parsing, direct/group routing with private-until-shared replies, the switchboard relay over Claude Code inter-agent messaging, headless `claude -p --resume`, and the stenographer watcher |
| **SmallChatMemex** | Knowledge-base compiler: the same Read → Extract → Embed → Link → Emit pipeline as `ToolCompiler`, driving `smallchat memex` |
| **SmallChatUI** | SwiftUI `WKWebView` wrapper (`AppWebView`) for rendering App/UI content, with sandboxed navigation and CSP injection |
| **SmallChat** | Umbrella module — imports and re-exports all of the above |
| **SmallChatApp** | macOS SwiftUI messenger for Claude Code sessions (direct + group chats, `@mentions`, stenographer), with the Compiler, Server, Manifest editor, Inspector, Resolver, Discovery, Apps, and Doctor panels under Toolkit |

## Security

Each control below says what it does and where it stops. None of them makes a model
immune to instructions inside the text it reads.

| Control | What it does |
|---------|--------------|
| **Dispatch Policy** | One rule set on every path that can run a tool (pinned phrase, cache hit, vector and overload match, protocol conformance, decomposed sub-intent): below HIGH a tool runs only with an LLM verifier's approval, destructive tools (MCP annotations) run by intent only at EXACT similarity or from a pinned phrase, and nothing below LOW runs. A denial runs nothing and returns the candidates. |
| **Intent Pinning** | Guards sensitive tools against semantic collisions. `exact` pins accept only their pinned phrases, compared as whole phrases (so "do not transfer funds" does not match "transfer funds"); `elevated` pins need a similarity of the intent's own embedding at or above their threshold (default 0.98). |
| **Argument Validation** | Every call is validated against the tool's JSON Schema `inputSchema` before it runs; a schema the validator cannot evaluate makes the tool uncallable rather than unchecked. `format` is not checked. |
| **Intent Sanitization** | Before embedding, `resolve` strips NUL and the other C0 control characters, collapses whitespace and truncates the intent to 1,024 characters; an empty intent is refused. |
| **Semantic Rate Limiting** | Opt-in (`RuntimeOptions.rateLimiter`): limits novel intents embedded per principal per time window, counting concurrent ones as they are admitted; over the limit, resolution returns `throttled` without embedding. |
| **No Intent Interning** | Intents are embedded on their own and never inserted into the tool-selector table or index, so long-running processes can't accumulate state per intent or dilute real tool candidates. |
| **Selector Namespacing** | Selectors of a class registered with `registerCoreClass` cannot be taken over by another class's category, overload or swizzle (`SelectorShadowingError`) unless marked swizzlable. `registerClass` itself does not check them. |
| **Schema Fingerprinting** | After `updateSchemaFingerprint(_:)` records a provider's changed schemas, cached resolutions made under the old ones are dropped on their next lookup. Call it when a provider reloads; nothing calls it for you. |
| **Bearer Token** | With `serve --auth`, every MCP request (all but `GET /health`) needs `Authorization: Bearer <token>`, compared in constant time. The token comes from `SMALLCHAT_MCP_TOKEN` or a file created with mode 0600 (in a 0700 directory when it creates one); a token file that group or other users can access is refused. OAuth is not implemented. |
| **Audit Log Integrity** | HMAC-SHA256 chain over every field of each entry, under a secret key (random per server unless you pass one; there is no built-in key). It detects edits to retained entries by anyone without the key, and still verifies after old entries are evicted. In memory only: it does not survive a restart. |
| **Connection Limits** | The MCP server closes connections beyond `maxConnections` and rejects bodies over `maxRequestBodyBytes` (413). |
| **DNS-Rebinding Protection** | A loopback-bound MCP server rejects (403) `Host` and `Origin` names other than `localhost`, `::1` and dotted-decimal IPv4 addresses in 127.0.0.0/8; a DNS name such as `127.0.0.1.nip.io` is refused even if it resolves to loopback. Origins in `allowedOrigins` are accepted. |
| **Sender Gating** | The channel server's allowlist of event senders (`SenderGate`), with identity validation, a sender cap and 6-hex-digit pairing codes compared in constant time. An empty allowlist admits every sender. The HTTP bridge additionally requires the shared secret, and its events are from the secret's identity (`httpBridgeSecretIdentity`), never from a sender the body names. |
| **Truth Ledger Reading** | `SmallChatTruth` refuses a truth format v2 stream with an edited line or a broken hash chain, or a line whose agent quorum breaks the spec's rules, and never counts an entry with an unknown or missing status, a struck entry, an unsigned TB, or a TB an agent signed without a quorum of agents or citing an evidence kind it doesn't know, as current truth. The chain shows a stream wasn't edited between its first and last line; it doesn't show who wrote it (key signatures are planned for 1.x). |
| **Messenger** | Separate channel, notary and REST secrets kept in the Keychain (0600 files outside macOS), headless sessions with an explicit tool list, a nonce-framed switchboard protocol, and escaping of truth markers inside untrusted text (see [the messenger](#the-smallchat-app-agent-messenger)). |
| **Concurrency** | Built in the Swift 6 language mode, so actor isolation and `Sendable` are checked by the compiler. Types that share mutable state across threads outside actors (for example `ToolClass`) are `@unchecked Sendable` behind locks, and blocking pipe reads run on dedicated threads. |

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
  `isError` when called. Arguments are validated against the tool's `inputSchema`
  first. Artifacts must be format 1.0 (recompile 0.x artifacts).
- **Resolution is read-only.** The `smallchat_resolve` meta-tool (listed unless
  `--no-resolve-tool`) proposes a tool for an intent — its name, tool id, tier,
  candidates and proof digest — and runs nothing; the client then calls that tool.
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
- **@stenographer.** A stenographer watches every chat. It is preloaded with the tombstones (TB) and unverified claims (UV) from your project wiki's truth ledger: the files Stenographer's `export_wiki_entries` writes (truth format v2, one file per writer; a file or a directory of them). A file with an edited line or a broken chain is refused, and then nothing is loaded until it is fixed: it might hold the strike that matters. Version 1 TBs (from Stenographer 0.x) carry no hash and don't count as truth. It objects when a message asserts a tombstoned value, and flags when a message relies on an unverified claim. Its notes are visible only to you. Ask it questions directly with `@stenographer`: a headless session answers with the ledger in its system prompt and only `Read`, `Grep` and `Glob` for tools, so it can read the chat's working directory and nothing else (no shell, web, MCP servers or messaging).
- **Live tool activity.** Each live session's card streams what it's doing, read from the tail of its transcript: the tool in flight (`Bash · Build the app`), the last few finished steps (✓/✗), or its latest line of prose.
- **Objection channel.** The app runs the loopback bridge Stenographer's `--objection-channel` posts to (`POST /event`, `X-Channel-Secret`), the same contract as smallchat's TS channel bridge. Each real-time objection lands in the offending agent's chats and, by default, is relayed into its live session as an interrupt so it can correct course. Tombstones agents draft arrive the same way and wait for you to approve them; the app approves through Stenographer's REST port with a separate notary secret, and sends Stenographer's REST token (`Authorization: Bearer`) on every REST call. The three secrets are generated by the app, are never the same value, and live in your Keychain, not in `messenger.json`. **Settings → Objection channel** has the ports, the channel secret, and a copyable Stenographer command that reads the secrets from the Keychain when it runs, so none lands in your shell history:
  ```bash
  SMALLCHAT_CHANNEL_SECRET="$(security find-generic-password -s 'dev.smallchat.messenger' -a 'channel-secret' -w)" \
  STENOGRAPHER_NOTARY_SECRET="$(security find-generic-password -s 'dev.smallchat.messenger' -a 'notary-secret' -w)" \
  STENOGRAPHER_REST_TOKEN="$(security find-generic-password -s 'dev.smallchat.messenger' -a 'rest-token' -w)" \
    npx -y @stenographer/core start <log-or-dir> \
    --objections deliver --objection-channel http://127.0.0.1:7337 --rest-port 8787 --require-notary
  ```
- **Tombstones with literals.** Sign a tombstone from the Stenographer page, or from any chat message with **Tombstone a Value…**. You give the claim, the evidence, and the literals (subject / dead value / current value) that objections can cite. The app never writes to a wiki file (each file has one writer, Stenographer): it submits the tombstone to Stenographer's REST API as a proposal (`POST /proposals`, drafted by `agent:smallchat-messenger`) and notarizes it in your name (`POST /proposals/:id/notarize`), so Stenographer mints the TB, signed by you, and exports it. The in-app stenographer starts objecting to those values as soon as Stenographer answers. This needs Stenographer 1.0 running with its REST API (`--rest-port`) and the notary secret. Literals follow Stenographer's rule: a bare value like `30` needs a subject; without one, the dead value needs at least 4 characters and an ASCII letter.
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
- **Channel events** — each injected event reaches Claude Code as a
  `notifications/claude/channel` notification; with `--two-way`, Claude Code can answer
  through a `reply` tool (the only tool the channel lists)
- **Sender gating** — an allowlist of event senders (`--sender-allowlist`); an empty
  allowlist admits everyone. Over the HTTP bridge the sender is the identity of the
  credential, never what the request body says (see below)
- **Permission relay** (`--permission-relay`) — Claude Code's permission requests are
  received and reported; verdicts are sent with `ChannelServer.sendPermissionVerdict(_:)`
  from code (the CLI only logs the requests)
- **MCP handshake** — `initialize` negotiates 2025-11-25, 2025-06-18 or 2024-11-05
- **HTTP bridge** (`--http-bridge`) — `POST /event` (`{content, meta?, timestamp?}`,
  authenticated with `X-Channel-Secret` or `Authorization: Bearer`; the secret from
  `SMALLCHAT_CHANNEL_SECRET` is required) injects an event into the channel; `GET /health`
  answers liveness. Every event is from the identity the secret authenticates
  (`--http-bridge-secret-identity`, default `bridge`) on the channel's own name: that
  identity is what the sender allowlist judges and what Claude Code sees as `meta.sender`.
  A body's `sender` and `channel` are ignored, and `meta` can't set `sender`, `source` or
  `user`. Permission verdicts over HTTP (`POST /permission`) are not implemented.
  The channel secret only authenticates posts to the bridge; never reuse it as
  stenographer's `STENOGRAPHER_NOTARY_SECRET`, or whoever can post events can also
  notarize tombstones.

The command exits when Claude Code closes its stdin.

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5.0+ | CLI command parsing |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | 0.15.0+ | Session persistence |
| [swift-nio](https://github.com/apple/swift-nio) | 2.70.0+ | MCP server, channel bridge and messenger HTTP (NIO) |
| [swift-collections](https://github.com/apple/swift-collections) | 1.1.0+ | `OrderedDictionary` for LRU cache |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.0.0..<6.0.0 | SHA-256 and HMAC on Linux only (Apple platforms use CryptoKit) |

No external embedding models are required. The built-in `LocalEmbedder` uses FNV-1a hash-based embeddings (384 dimensions by default): they match words and character trigrams, not meaning, so they suit development and tests. For semantic matching, provide an `Embedder` conformance backed by an embedding model, and give it a `fingerprint` so artifacts record which model produced their vectors.

## Ecosystem

smallchat-swift is part of the smallchat suite. It follows
[@smallchat/core](https://github.com/johnnyclem/smallchat) (TypeScript) 1.0 and runs its
`spec/` vectors, and it is wired to [Stenographer](https://github.com/johnnyclem/stenographer):
`SmallChatTruth` reads Stenographer's truth format v2 and runs its golden fixtures, the
messenger receives Stenographer's objections on its channel bridge and submits
tombstones to Stenographer's REST API for a person to notarize, and the copied launch
command runs `npx -y @stenographer/core`. None of these is a SwiftPM dependency: the
contracts are the vendored fixtures.

[@shorthand/core](https://github.com/johnnyclem/short-hand) is a separate TypeScript
package. This repo's `SmallChatShorthand`, `SmallChatImportance`, `SmallChatCRDT` and
`SmallChatCompaction` are ports of smallchat's 0.4-era modules (TS PRs #55–#58), which
@shorthand/core 1.0 has since absorbed and changed; they are not a port of it.

[`docs/ecosystem/`](docs/ecosystem/) holds an archived pre-1.0 evaluation of how this repo
related to AgentVault, smallchat, Stenographer and Short-Hand; its findings about this repo
(nothing wired, no CI, no LICENSE) are out of date.

## Development

```bash
# Build
swift build                              # Debug build
swift build -c release                   # Optimized release build

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
├── Tests/                          # One *Tests target per module above, plus SmallChatConformanceTests
│   └── Fixtures/                   # Vendored contracts: spec/ (@smallchat/core), truth-format/ (Stenographer)
├── Scripts/                        # sync-spec.sh, sync-truth-fixtures.sh
├── examples/                       # loom-mcp manifest, registry entries (GitHub, Slack, Postgres, loom)
├── docs/                           # Archived: ecosystem evaluation, 0.5.0 roadmap
└── docs-site/                      # Docusaurus documentation site
```

## License

[MIT](LICENSE)

---

<div align="center">

Built with Swift. Inspired by Smalltalk.

[smallchat.dev](https://smallchat.dev)

</div>
