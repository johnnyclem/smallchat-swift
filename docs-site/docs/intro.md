---
sidebar_position: 1
title: Introduction
---

# smallchat-swift

> Object-oriented inference. A native Swift tool compiler for the age of agents.

Your agent has 50 tools. The LLM sees all 50 in its context window every single turn, burning tokens and degrading selection accuracy. You write routing logic, maintain tool registries, and pray the model picks the right one.

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it to at most one tool, by embedding similarity, and runs that tool only when its dispatch policy allows; otherwise it asks. No prompt stuffing. No selection lottery.

This is the **Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat), for Apple platforms and Linux. Version 1.0 follows @smallchat/core 1.0's dispatch rules and artifact format; [Parity with @smallchat/core](#parity-with-smallchatcore) below says exactly what is checked.

## Why smallchat-swift?

- **Semantic resolution, separate from execution** — vector similarity proposes at most one tool for an intent; a tool runs only by exact id, or by intent when the dispatch policy allows it
- **Checked calls** — arguments are validated against each tool's JSON Schema before anything runs
- **Swift 6 language mode** — actors and structured concurrency, with `Sendable` checked by the compiler
- **MCP** — compile MCP servers' tools into one artifact and serve them over Streamable HTTP, each call running exactly the named tool
- **Claude Code integration** — a channel server for pushing events into Claude Code, and (on macOS) a messenger for your Claude Code sessions

## Quick Look

```swift
import SmallChat

let runtime = try await MCPToolkit.load(source: "tools.toolkit.json").runtime

// Which tool does this intent mean? (nothing runs)
let resolution = try await runtime.resolve("find flights")

// Run exactly one tool by id, or resolve and run by intent
let byId = try await runtime.dispatchById("flights/search_flights", args: ["to": "NYC"])
let result = try await runtime.dispatch("find flights", args: ["to": "NYC"])

// Fluent API
let content = try await runtime
    .dispatch("find flights")
    .withArgs(["to": "NYC"])
    .exec()

// Stream token-by-token
for try await token in await runtime.inferenceStream("find flights", args: ["to": "NYC"]) {
    print(token, terminator: "")
}
```

```bash
# Compile tools from your MCP servers
swift run smallchat compile --source ~/.mcp.json

# Test resolution
swift run smallchat resolve tools.toolkit.json "search for code"

# Start an MCP server
swift run smallchat serve --source ./manifests --port 3001
```

## What's New in 1.0

1.0 is a breaking release; the repository's `MIGRATION.md` says how to update from 0.6,
and `CHANGELOG.md` lists every change.

- **Resolve, then run by id.** `resolve` runs nothing; `dispatchById` runs exactly one
  tool; intent `dispatch` runs a match only when the dispatch policy allows it (below
  HIGH only with an LLM verifier's approval, destructive tools only at EXACT similarity
  or from a pinned phrase).
- **Artifact format 1.0**, @smallchat/core's: content-hashed and pinned to the embedder
  that produced its vectors.
- **An MCP server that runs exactly the tool you call**, over Streamable HTTP
  (2025-11-25 and 2025-06-18), with the read-only `smallchat_resolve` meta-tool and an
  optional bearer token. OAuth and the TLS settings that nothing enforced are gone.
- **Linux and iOS.** CI builds and tests on macOS and Linux (Swift 6.1, 6.3, 6.4) and
  builds the libraries for iOS.
- **`SmallChatTruth`** reads Stenographer's truth format v2 and fails closed on anything
  it cannot verify. Agents settle claims only together: a TB an agent signs counts only
  with a quorum of two or more agent sessions agreeing from different angles within
  15 minutes.

## Parity with @smallchat/core

What `swift test` checks is the set of vectors in @smallchat/core's `spec/`, copied into
`Tests/Fixtures/spec`: canonical call digests (RFC 8785 JSON and the domain-separated
SHA-256), canonical tool ids, score quantization, ranking and tier boundaries, the
outcome, decision, tier, chosen tool and candidate order of each resolve case, and the
artifact fixtures (the golden artifact, every invalid one, every embedder mismatch, and
the golden manifest compiling to the golden content hash).

Outside those vectors the TypeScript runtime is the reference. Proof digests are per
runtime, and argument coercion, the semantic map, observer feedback, the decision log,
replay and explain are not ported yet. The only built-in embedder is the hash embedder,
so artifacts compiled by @smallchat/core with ONNX need an `Embedder` of yours that
declares the same fingerprint.

## Next Steps

- [Install smallchat-swift](/getting-started/installation)
- [Understand the architecture](/concepts/architecture)
- [Explore the CLI](/cli/commands)
