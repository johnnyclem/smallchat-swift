---
sidebar_position: 1
title: Introduction
---

# smallchat-swift

> Object-oriented inference. A native Swift tool compiler for the age of agents.

Your agent has 50 tools. The LLM sees all 50 in its context window every single turn, burning tokens and degrading selection accuracy. You write routing logic, maintain tool registries, and pray the model picks the right one.

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it — semantically, deterministically, in microseconds. No prompt stuffing. No selection lottery.

This is the **native Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat) — same architecture, same semantics, built for Apple platforms with Swift concurrency, actors, and the Swift type system.

## Why smallchat-swift?

- **Semantic resolution** — Vector similarity finds the right tool from natural language intent
- **Swift 6 native** — Actors, structured concurrency, `Sendable` types throughout
- **MCP compatible** — Compile and serve tools via the Model Context Protocol
- **Production ready** — Rate limiting, circuit breakers, OAuth, audit logging
- **Claude Code integration** — Bidirectional channel protocol for IDE tool dispatch

## Quick Look

```swift
import SmallChat

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

// Dispatch by intent
let result = try await runtime.dispatch("find flights", args: ["to": "NYC"])

// Fluent API
let content = try await runtime
    .dispatch("find flights")
    .withArgs(["to": "NYC"])
    .exec()

// Stream token-by-token
for try await token in runtime.inferenceStream("find flights", args: ["to": "NYC"]) {
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

## What's New in 0.3.0

- **Intent sanitization** — Null byte stripping, control character removal, length limits on dispatch pipeline inputs
- **Audit log integrity** — HMAC-SHA256 hash chain on audit entries with `verifyChain()` tamper detection
- **Server hardening** — Max connections, max request body size, graceful shutdown with drain timeout
- **Server metrics** — `/metrics` endpoint tracking request counts, error rates, connections, uptime
- **TLS configuration** — Certificate pinning, minimum TLS version, development/production presets
- **Identity validation** — Sender format validation, max sender limits, constant-time pairing code verification
- **Connection tracking** — Real-time active/peak connection monitoring in NIO handler

## Next Steps

- [Install smallchat-swift](/getting-started/installation)
- [Understand the architecture](/concepts/architecture)
- [Explore the CLI](/cli/commands)
