---
sidebar_position: 1
title: Installation
---

# Installation

## Requirements

- **Swift 6.1+** (Xcode 16.3+ on macOS)
- **macOS 14+**, **Linux**, or **iOS 17+** (libraries only; see
  [Platform Support](../modules/overview#platform-support) for what builds where)

## Swift Package Manager

Add smallchat-swift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
]
```

:::note
Version tags start at `1.0.0`, which is tagged when the release is published. Until
then, pin a commit with `revision:`. Earlier versions were never tagged.
:::

Then add the modules you need to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        // Import everything
        .product(name: "SmallChat", package: "smallchat-swift"),
    ]
),
```

### Selective Imports

You can import individual modules for a smaller dependency footprint:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SmallChatCore", package: "smallchat-swift"),
        .product(name: "SmallChatRuntime", package: "smallchat-swift"),
        .product(name: "SmallChatCompiler", package: "smallchat-swift"),
    ]
),
```

Available modules:

| Module | Purpose |
|--------|---------|
| `SmallChat` | Umbrella — imports everything |
| `SmallChatCore` | Type system, selectors, dispatch tables |
| `SmallChatRuntime` | Tool runtime, dispatch pipeline, fluent API |
| `SmallChatCompiler` | 4-phase compilation pipeline |
| `SmallChatEmbedding` | Embedder and vector index |
| `SmallChatTransport` | HTTP, SSE, stdio and local transports, auth, middleware, importers |
| `SmallChatMCP` | MCP server (Streamable HTTP), MCP client, toolkits |
| `SmallChatChannel` | Claude Code channel server and its HTTP bridge |
| `SmallChatTruth` | Reader for Stenographer's truth format v2 |
| `SmallChatDream`, `SmallChatMemex` | Memory-driven recompilation, knowledge-base compiler |
| `SmallChatShorthand`, `SmallChatImportance`, `SmallChatCRDT`, `SmallChatCompaction` | Text primitives, importance scoring, replicated types, compaction verification |
| `SmallChatAgents` | The messenger's core (macOS and Linux) |
| `SmallChatUI` | `WKWebView` wrapper for App/UI surfaces (Apple platforms) |

See the [module overview](../modules/overview) for what each contains and where it builds.

## CLI Tool

To use the CLI directly:

```bash
# Clone and run
git clone https://github.com/johnnyclem/smallchat-swift.git
cd smallchat-swift
swift run smallchat --help
```

Or build a release binary:

```bash
swift build -c release
cp .build/release/smallchat /usr/local/bin/
```

## Verify Installation

```bash
swift run smallchat doctor
```

This runs diagnostics to verify your environment is correctly configured.

## Dependencies

smallchat-swift depends on the following packages (managed automatically by SPM):

| Package | Purpose |
|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI command parsing |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | Session persistence |
| [swift-nio](https://github.com/apple/swift-nio) | MCP server, channel bridge and messenger HTTP |
| [swift-collections](https://github.com/apple/swift-collections) | OrderedDictionary for LRU cache |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 and HMAC, on Linux only (Apple platforms use CryptoKit) |

All dependencies are resolved automatically when you build.
