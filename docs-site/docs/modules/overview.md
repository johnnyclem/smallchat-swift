---
sidebar_position: 1
title: Module Overview
---

# Module Overview

smallchat-swift is organized into 8 modules with clear dependency boundaries. Import `SmallChat` for everything, or pick individual modules for a smaller footprint.

## Module Map

```
SmallChat (umbrella)
│
├── SmallChatCore              Zero external dependencies
│   ├── Types/                 ToolSelector, ToolIMP, ToolResult, DispatchEvent
│   ├── SCObject/              Objective-C-style object system
│   ├── ToolClass              Dispatch tables, overloads, ISA chain
│   ├── Canonicalize           Intent → canonical selector
│   ├── ResolutionCache        LRU cache, version-aware
│   ├── SelectorTable          Selector interning
│   ├── OverloadTable          C++-style overload resolution
│   ├── SelectorNamespace      Core selector protection
│   ├── IntentPinRegistry      Semantic collision prevention
│   ├── SemanticRateLimiter    DoS protection
│   └── VectorMath             Accelerate-based cosine similarity
│
├── SmallChatRuntime           → Core
│   ├── ToolRuntime            Top-level runtime actor
│   ├── Dispatch               Hot-path dispatch (toolkitDispatch)
│   ├── DispatchContext         Runtime environment
│   └── DispatchBuilder        Fluent API
│
├── SmallChatCompiler          → Core
│   ├── ToolCompiler           4-phase pipeline
│   ├── Parser                 Manifest parsing
│   ├── SemanticGrouping       Overload detection
│   └── CompilerOptions        Configuration
│
├── SmallChatEmbedding         → Core
│   ├── LocalEmbedder          FNV-1a + trigram embedder
│   └── MemoryVectorIndex      Brute-force cosine search
│
├── SmallChatTransport         → Core, NIO
│   ├── Protocols/Transport    Universal transport interface
│   ├── Implementations/       HTTP, Stdio, SSE, Local
│   ├── Middleware/             Retry, CircuitBreaker, Timeout
│   ├── Auth/                  Bearer, OAuth2
│   ├── Streaming/             SSE, NDJSON parsers
│   └── Importers              OpenAPI, Postman
│
├── SmallChatMCP               → Core, Runtime, Transport, SQLite, NIO
│   ├── MCPServer              NIO HTTP server
│   ├── MCPRouter              JSON-RPC routing
│   ├── MCPClientTransport     Client connections
│   ├── SessionStore           SQLite persistence
│   ├── OAuthManager           OAuth 2.1
│   ├── RateLimiter            Sliding window
│   ├── SSEBroker              Event broadcasting
│   ├── ResourceRegistry       MCP resources
│   ├── PromptRegistry         MCP prompts
│   ├── AuditLog               Compliance logging
│   ├── JsonRPC                JSON-RPC 2.0 codec
│   └── Artifact               Compiled artifact I/O
│
├── SmallChatChannel           → Core, MCP
│   ├── ChannelServer          Stdio JSON-RPC server
│   ├── ChannelAdapter         MCP → Channel bridge
│   ├── ChannelTypes           Message/event definitions
│   ├── SenderGate             Permission relay
│   └── ChannelUtils           Serialization helpers
│
└── SmallChatCLI               → All modules, ArgumentParser
    ├── main                   Entry point
    ├── CompileCommand
    ├── ServeCommand
    ├── ChannelCommand
    ├── ResolveCommand
    ├── InspectCommand
    ├── InitCommand
    ├── DocsCommand
    ├── ReplCommand
    └── DoctorCommand
```

## Dependency Graph

```
                    SmallChatCore
                   /    |    |    \
                  /     |    |     \
           Runtime  Compiler Embedding Transport
              |                        |
              |                      (NIO)
              |                        |
              +--------+  +------------+
                       |  |
                     SmallChatMCP
                     (+ SQLite)
                        |
                   SmallChatChannel
                        |
                    SmallChatCLI
                  (+ ArgumentParser)
```

## External Dependencies

| Package | Used By | Purpose |
|---------|---------|---------|
| [swift-collections](https://github.com/apple/swift-collections) | Core | `OrderedDictionary` for LRU cache |
| [swift-nio](https://github.com/apple/swift-nio) | Transport, MCP | HTTP server and client |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | MCP | Session persistence, audit log |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI | Command-line parsing |

## Choosing Modules

| Use Case | Modules |
|----------|---------|
| Embed in an iOS/macOS app | `SmallChatCore`, `SmallChatRuntime`, `SmallChatEmbedding` |
| Compile tool manifests | Add `SmallChatCompiler` |
| Connect to remote tools | Add `SmallChatTransport` |
| Run an MCP server | Add `SmallChatMCP` |
| Integrate with Claude Code | Add `SmallChatChannel` |
| Everything | `SmallChat` (umbrella) |

## Platform Support

| Module | macOS 14+ | iOS 17+ | Notes |
|--------|-----------|---------|-------|
| SmallChatCore | Yes | Yes | Pure Swift + Accelerate |
| SmallChatRuntime | Yes | Yes | |
| SmallChatCompiler | Yes | Yes | |
| SmallChatEmbedding | Yes | Yes | |
| SmallChatTransport | Yes | Yes | NIO works on all Apple platforms |
| SmallChatMCP | Yes | Limited | Server typically macOS only |
| SmallChatChannel | Yes | No | Claude Code is desktop only |
| SmallChatCLI | Yes | No | CLI tool |
