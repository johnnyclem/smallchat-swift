---
sidebar_position: 4
title: Claude Code Integration
---

# Claude Code Integration

The `SmallChatChannel` module provides bidirectional integration with Claude Code via a stdio JSON-RPC protocol.

## Overview

The channel protocol enables:
- Claude Code to discover and invoke smallchat tools
- smallchat to send events back to the Claude Code UI
- Permission gating for tool execution requests
- Metadata filtering for security

## Starting the Channel Server

### CLI

```bash
swift run smallchat channel
```

This starts a stdio JSON-RPC server that Claude Code can connect to.

### Programmatic

```swift
import SmallChatChannel

let config = ChannelServerConfig(
    // configuration options
)

let server = ChannelServer(config: config)
server.start()
```

## Architecture

```
Claude Code IDE
      │
      │ stdio (JSON-RPC 2.0)
      ▼
┌─────────────────┐
│  ChannelServer   │  Parses JSON-RPC, routes methods
│                  │
│  ┌────────────┐  │
│  │  Adapter   │  │  Bridges MCP notifications → ChannelEvents
│  └────────────┘  │
│  ┌────────────┐  │
│  │ SenderGate │  │  Permission relay for tool execution
│  └────────────┘  │
└─────────────────┘
      │
      ▼
  ToolRuntime (dispatch)
```

## Channel Adapter

The `ChannelAdapter` bridges MCP channel notifications into smallchat's event system:

- Parses MCP notification params into `ChannelEvent` objects
- Serializes events to `<channel>` XML tags for prompt injection
- Filters metadata fields for security

## Sender Gate

The `SenderGate` implements a permission relay for tool execution:

```swift
let gate = server.getSenderGate()

// When a tool execution request arrives:
// 1. Claude Code sends a permission request
// 2. SenderGate holds the request pending
// 3. User approves/denies in the IDE
// 4. Verdict is relayed back

server.sendPermissionVerdict(PermissionVerdict(
    requestId: "req_123",
    allowed: true
))
```

## Events

The channel emits events for lifecycle management:

```swift
for await event in server.events {
    switch event {
    case .initialized:
        print("Channel initialized")
    case .toolExecuted(let name, let result):
        print("Tool \(name) executed")
    case .error(let message):
        print("Error: \(message)")
    case .shutdown:
        print("Channel shutting down")
    }
}
```

## JSON-RPC Messages

The channel uses standard JSON-RPC 2.0:

```swift
struct JsonRpcMessage: Sendable, Codable {
    var jsonrpc: String       // "2.0"
    var id: AnyCodableValue?  // Request ID
    var method: String?       // Method name
    var params: [String: AnyCodableValue]?
    var result: AnyCodableValue?
    var error: JsonRpcError?
}
```

## Outbound Messages

Read outbound messages from the server's stream:

```swift
for await message in server.outboundMessages {
    // Write to stdout for Claude Code to read
    print(message)
}
```

## Event Injection

Inject events programmatically:

```swift
let success = await server.injectEvent(ChannelEvent(
    type: .toolListChanged,
    data: [:]
))
```

## Configuration

```swift
let config = ChannelServerConfig(
    // Channel-specific options
)
```

## Security Considerations

- **Metadata filtering** — The adapter strips sensitive metadata before forwarding to Claude Code
- **Permission gating** — All tool executions require explicit user approval via the `SenderGate`
- **Input validation** — JSON-RPC messages are validated before processing
- **No arbitrary code execution** — The channel only exposes registered tools, not arbitrary system access
