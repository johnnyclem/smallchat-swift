---
sidebar_position: 2
title: Quick Start
---

# Quick Start

Get from zero to semantic tool dispatch in under 5 minutes.

## 1. Compile Your Tools

If you have an existing MCP configuration (e.g., `~/.mcp.json`), compile it:

```bash
swift run smallchat compile --source ~/.mcp.json
```

This produces a `tools.toolkit.json` artifact in format 1.0 (the @smallchat/core format): providers, tools, embedded selectors, the embedder's fingerprint and a content hash. Two tools that embed almost identically are a compile error; give them distinct descriptions, or pass `--allow-duplicates`.

You can also compile from a directory of manifests:

```bash
swift run smallchat compile --source ./manifests/
```

## 2. Test Resolution

Before writing code, test that intent resolution works:

```bash
# See which tool resolves for an intent
swift run smallchat resolve tools.toolkit.json "search for code"

# Interactive exploration
swift run smallchat repl tools.toolkit.json
```

Both print the outcome (`resolved`, `needs-disambiguation` or `unresolved`), the tier, the chosen tool id, the ranked candidates and the proof digest. Nothing runs.

## 3. Use in Code

```swift
import SmallChat

// Load the compiled toolkit
let toolkit = try await MCPToolkit.load(source: "tools.toolkit.json")
let runtime = toolkit.runtime

// Which tool does an intent mean? Nothing runs.
let resolution = try await runtime.resolve("find flights")
print(resolution.outcome, resolution.chosen ?? "-")

// Run exactly one tool by id (arguments are checked against its inputSchema)
let result = try await runtime.dispatchById("flights/search_flights", args: ["to": "NYC"])

// Or resolve and run in one call
let byIntent = try await runtime.dispatch("find flights", args: ["to": "NYC"])
print(byIntent.isError)  // true if nothing ran or the tool failed
print(byIntent.metadata?[DispatchMetadataKey.outcome] ?? "")  // "resolved", "needs-disambiguation", ...
```

An intent runs a tool on its own only at HIGH similarity or above (MEDIUM and LOW
need an `LLMClient` verifier), and destructive tools only at EXACT similarity or from
a pinned phrase. Otherwise the result lists the candidates for the user to choose.

## 4. Use the Fluent API

For more control, use the builder pattern:

```swift
let content = try await runtime
    .dispatch("find flights")
    .withArgs(["to": "NYC"])
    .withTimeout(.seconds(30))
    .withMetadata(["source": .string("user-query")])
    .exec()
```

## 5. Stream Results

For real-time output:

```swift
// Token-level streaming
for try await token in await runtime.inferenceStream("explain code", args: ["code": snippet]) {
    print(token, terminator: "")
}

// Event-level streaming
for try await event in await runtime.dispatchStream("find flights", args: ["to": "NYC"]) {
    switch event {
    case .resolving(let intent):
        print("Resolving: \(intent)")
    case .toolStart(let name, _, let confidence, _):
        print("Dispatching to \(name) (confidence: \(confidence))")
    case .chunk(let content, _):
        print("Chunk: \(content)")
    case .done(let result):
        print("Done: \(result.content)")
    case .error(let msg, _):
        print("Error: \(msg)")
    default:
        break
    }
}
```

## 6. Start an MCP Server

Serve your compiled tools over HTTP:

```bash
swift run smallchat serve --source ./manifests --port 3001
```

This starts an MCP server over Streamable HTTP with:
- The MCP endpoint at `http://127.0.0.1:3001/mcp` (tools listed as `<provider>__<tool>`)
- Health check at `GET /health`

Each tool runs at its provider manifest's `endpoint`; tools without one are listed but fail when called. The read-only `smallchat_resolve` tool proposes a tool for an intent without running it.

## Next Steps

- [Your First Dispatch](/getting-started/first-dispatch) — A deeper walkthrough
- [Architecture](/concepts/architecture) — Understand the runtime model
- [Compilation Guide](/guides/compilation) — Advanced compiler options
