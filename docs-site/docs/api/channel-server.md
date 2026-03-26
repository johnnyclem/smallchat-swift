---
sidebar_position: 8
title: ChannelServer
---

# ChannelServer

<span class="module-badge">SmallChatChannel</span>

Bidirectional stdio JSON-RPC server for Claude Code integration.

```swift
actor ChannelServer
```

## Initialization

```swift
init(config: ChannelServerConfig)
```

## Properties

### outboundMessages

Stream of JSON-RPC messages to send to Claude Code via stdout:

```swift
var outboundMessages: AsyncStream<String>
```

### events

Stream of channel lifecycle events:

```swift
var events: AsyncStream<ChannelServerEvent>
```

## Lifecycle

### start

Begin processing:

```swift
func start()
```

### shutdown

Stop the server:

```swift
func shutdown()
```

## Message Handling

### handleLine

Process an inbound JSON-RPC message from stdin:

```swift
func handleLine(_ line: String) async
```

## Events & Permissions

### injectEvent

Programmatically inject a channel event:

```swift
func injectEvent(_ event: ChannelEvent) async -> Bool
```

Returns `true` if the event was accepted.

### sendPermissionVerdict

Respond to a pending permission request:

```swift
func sendPermissionVerdict(_ verdict: PermissionVerdict)
```

## Accessors

```swift
func getAdapter() -> ClaudeCodeChannelAdapter
func getSenderGate() -> SenderGate
func getConfig() -> ChannelServerConfig
func isInitialized() -> Bool
func getPendingPermissions() -> [String: PermissionRequest]
```

## JSON-RPC Types

### JsonRpcMessage

```swift
struct JsonRpcMessage: Sendable, Codable {
    var jsonrpc: String              // "2.0"
    var id: AnyCodableValue?         // Request ID
    var method: String?              // Method name
    var params: [String: AnyCodableValue]?
    var result: AnyCodableValue?
    var error: JsonRpcError?
}
```

### JsonRpcError

```swift
struct JsonRpcError: Sendable, Codable, Equatable {
    var code: Int
    var message: String
    var data: AnyCodableValue?
}
```

## Example

```swift
import SmallChatChannel

let config = ChannelServerConfig()
let server = ChannelServer(config: config)

// Start the server
server.start()

// Process inbound messages (from stdin)
Task {
    for try await line in FileHandle.standardInput.bytes.lines {
        await server.handleLine(line)
    }
}

// Forward outbound messages (to stdout)
Task {
    for await message in server.outboundMessages {
        print(message)
        fflush(stdout)
    }
}

// Handle events
Task {
    for await event in server.events {
        switch event {
        case .initialized:
            // Channel ready
            break
        case .shutdown:
            // Clean up
            break
        default:
            break
        }
    }
}
```

## SenderGate

Permission relay for tool execution:

```swift
let gate = await server.getSenderGate()

// Pending permissions are tracked
let pending = await server.getPendingPermissions()

// Approve a pending request
server.sendPermissionVerdict(PermissionVerdict(
    requestId: "req_123",
    allowed: true
))
```

## ChannelAdapter

Bridges MCP notifications to channel events:

```swift
let adapter = await server.getAdapter()
// The adapter:
// - Parses MCP notification params → ChannelEvent
// - Serializes events to <channel> XML tags
// - Filters sensitive metadata
```
