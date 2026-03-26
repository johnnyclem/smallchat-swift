---
sidebar_position: 1
title: Installation
---

# Installation

## Requirements

- **Swift 6.0+**
- **macOS 14+** or **iOS 17+**
- Xcode 16+ (for development)

## Swift Package Manager

Add smallchat-swift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "0.2.0"),
]
```

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
| `SmallChatTransport` | HTTP, SSE, stdio transports |
| `SmallChatMCP` | MCP server implementation |
| `SmallChatChannel` | Claude Code channel integration |

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
| [swift-nio](https://github.com/apple/swift-nio) | HTTP/SSE transport |
| [swift-collections](https://github.com/apple/swift-collections) | OrderedDictionary for LRU cache |

All dependencies are resolved automatically when you build.
