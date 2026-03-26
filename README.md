# smallchat-swift

> Object-oriented inference. A native Swift tool compiler for the age of agents.

[smallchat.dev](https://smallchat.dev)

---

Your agent has 50 tools. The LLM sees all 50 in its context window every single turn, burning tokens and degrading selection accuracy. You write routing logic, maintain tool registries, and pray the model picks the right one.

**smallchat compiles your tools into a dispatch table.** The LLM expresses intent. The runtime resolves it — semantically, deterministically, in microseconds. No prompt stuffing. No selection lottery.

This is the **native Swift implementation** of [smallchat](https://github.com/johnnyclem/smallchat) — same architecture, same semantics, built for Apple platforms with Swift concurrency, actors, and the Swift type system.

```bash
swift run smallchat compile --source ~/.mcp.json
```

One command. Point it at your MCP config, a directory of manifests, or any MCP server repo. Out comes a compiled artifact with embedded vectors, dispatch tables, and resolution caching — ready to serve.

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "0.2.0"),
]
```

Then add the libraries you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SmallChat", package: "smallchat-swift"),
    ]
),
```

Requires Swift 6.0+, macOS 14+, or iOS 17+.

## See It Work

```bash
# Compile tools from your MCP servers
swift run smallchat compile --source ~/.mcp.json

# Ask it a question — see which tool it picks and why
swift run smallchat resolve tools.toolkit.json "search for code"

# Start an MCP-compatible server
swift run smallchat serve --source ./manifests --port 3001

# Scaffold a new project
swift run smallchat init my-app --template agent

# Interactive REPL
swift run smallchat repl tools.toolkit.json
```

## Use It in Code

```swift
import SmallChat

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

let result = try await runtime.dispatch("find flights", args: ["to": "NYC"])

// Fluent API
let content = try await runtime
    .dispatch()
    .intent("find flights")
    .withArgs(["to": "NYC"])
    .exec()

// Or stream token-by-token
for try await token in runtime.inferenceStream("find flights", args: ["to": "NYC"]) {
    print(token, terminator: "")
}
```

## What's New in 0.2.0

- **Claude Code channel protocol** — Bidirectional stdio JSON-RPC integration with Claude Code
- **Security hardening** — Intent pinning, selector namespacing, semantic rate limiting, sender-gated permissions
- **Actor-based concurrency** — Thread-safe dispatch, caching, and session management via Swift actors
- **SQLite session persistence** — Durable session storage for MCP server connections
- **Fluent dispatch API** — Chainable `.dispatch().intent().withArgs().exec()` with Swift type inference
- **NIO-based transport** — High-performance HTTP, SSE, and stdio transports built on SwiftNIO
- **New CLI commands** — `init`, `docs`, `repl` for project scaffolding, documentation, and interactive exploration

## How It Works

smallchat borrows its architecture from the Smalltalk/Objective-C runtime. Tools are objects. Intents are messages. Dispatch is semantic.

The LLM says *what* it wants. The runtime figures out *which tool* handles it — using vector similarity, resolution caching, superclass traversal, and fallback chains. No routing code. No tool selection prompts.

```
User intent "find recent docs"
  → Canonicalize: "find:recent:docs"
  → Embed: [0.23, 0.15, ..., 0.89] (384 dims)
  → Vector search: cosine similarity > 0.75
  → Overload resolution: strict type matching
  → Dispatch to best match
```

The Swift implementation maps Objective-C runtime concepts directly:

| Objective-C / Smalltalk | smallchat-swift |
|-------------------------|-----------------|
| Class | `ToolClass` |
| Selector | `ToolSelector` |
| IMP (method pointer) | `ToolIMP` protocol |
| `objc_msgSend` | `DispatchContext.resolveToolIMP()` |
| Method cache | `ResolutionCache` (LRU, version-aware) |
| ISA chain | Superclass traversal fallback |
| Category | Provider extensions |
| Method swizzling | Hot-reload schema invalidation |

## CLI

| Command | Description |
|---------|-------------|
| `compile` | Compile manifests into a dispatch artifact |
| `serve` | Start an MCP-compatible server |
| `channel` | Claude Code channel server |
| `resolve` | Test intent-to-tool resolution |
| `inspect` | Examine a compiled artifact |
| `init` | Scaffold a new project from a template |
| `docs` | Generate Markdown docs from a compiled artifact |
| `repl` | Interactive shell for testing resolution |

## Modules

| Module | Description |
|--------|-------------|
| `SmallChatCore` | Type system, selectors, dispatch tables, resolution cache |
| `SmallChatRuntime` | Tool runtime, dispatch pipeline, fluent API |
| `SmallChatCompiler` | 4-phase compilation: parse → embed → link → output |
| `SmallChatEmbedding` | Local FNV-1a/trigram embedder, in-memory vector index |
| `SmallChatTransport` | HTTP, SSE, stdio transports, auth, retry, circuit breaker |
| `SmallChatMCP` | MCP server, SSE broker, rate limiter, session store |
| `SmallChatChannel` | Claude Code channel integration, sender gate |
| `SmallChat` | Umbrella module — imports everything |

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI command parsing |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | Session persistence |
| [swift-nio](https://github.com/apple/swift-nio) | HTTP/SSE transport |
| [swift-collections](https://github.com/apple/swift-collections) | OrderedDictionary for LRU cache |

## Development

```bash
swift build           # Build all targets
swift test            # Run test suite
swift run smallchat   # Run the CLI
```

## License

MIT
