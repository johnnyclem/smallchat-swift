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

This produces a `tools.toolkit.json` artifact containing embedded vectors, dispatch tables, and resolution metadata.

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

The REPL lets you type natural language intents and see which tools they resolve to, with confidence scores and resolution paths.

## 3. Use in Code

```swift
import SmallChat

// Create the runtime
let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

// Dispatch by intent — the runtime finds the right tool
let result = try await runtime.dispatch(
    "find flights",
    args: ["to": "NYC"]
)

print(result.content)  // Tool output
print(result.isError)  // false if successful
```

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
for try await token in runtime.inferenceStream("explain code", args: ["code": snippet]) {
    print(token, terminator: "")
}

// Event-level streaming
for try await event in runtime.dispatchStream("find flights", args: ["to": "NYC"]) {
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

This starts an MCP-compatible server with:
- JSON-RPC endpoint at `POST /`
- SSE streaming at `GET /sse`
- Health check at `GET /health`
- Discovery at `GET /.well-known/mcp.json`

## Next Steps

- [Your First Dispatch](/getting-started/first-dispatch) — A deeper walkthrough
- [Architecture](/concepts/architecture) — Understand the runtime model
- [Compilation Guide](/guides/compilation) — Advanced compiler options
