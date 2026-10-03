---
sidebar_position: 8
title: ChannelServer
---

# ChannelServer

<span class="module-badge">SmallChatChannel</span>

A Claude Code channel: an MCP server over stdio (JSON-RPC 2.0) that declares the
`claude/channel` capability and pushes events into the Claude Code session as
`notifications/claude/channel` notifications. With `twoWay`, it lists one tool (the
reply tool, `reply` by default) that Claude Code calls to answer.

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

Begin processing (emits `.ready`):

```swift
func start()
```

### startHTTPBridge

When `httpBridge` is configured, serve `POST /event` (authenticated with
`X-Channel-Secret` or `Authorization: Bearer`; `httpBridgeSecret` is required) and
`GET /health`. Each event is injected as if `injectEvent(_:)` were called; a rejected
event gets `403`. Every event is from the identity the secret authenticates
(`httpBridgeSecretIdentity`, `"bridge"` by default) on `channelName`: that is the sender
the gate judges, and a body's `sender` and `channel` are ignored. Returns the bound
port, or nil when the bridge is not configured; throws `ChannelBridgeError` without a
secret or with a blank identity.

```swift
@discardableResult
func startHTTPBridge() async throws -> Int?
```

### shutdown

Stop the server and its HTTP bridge:

```swift
func shutdown() async
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

With `permissionRelay`, Claude Code's permission requests arrive as
`.permissionRequestReceived` events and wait in `getPendingPermissions()`. Answer one:

```swift
func sendPermissionVerdict(_ verdict: PermissionVerdict)
```

```swift
await server.sendPermissionVerdict(PermissionVerdict(requestId: "abcde", behavior: .allow))
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

let config = ChannelServerConfig(channelName: "ci", twoWay: true)
let server = ChannelServer(config: config)

// Forward outbound messages (to stdout)
let outbound = await server.outboundMessages
Task {
    for await message in outbound {
        print(message)
        fflush(stdout)
    }
}

// Handle events
let events = await server.events
Task {
    for await event in events {
        switch event {
        case .initialized:
            break   // Claude Code finished the handshake
        case .reply(let channel, let message, _):
            print("reply on \(channel): \(message)")
        case .senderRejected(let sender):
            print("rejected event from \(sender ?? "unknown")")
        default:
            break
        }
    }
}

await server.start()

// Process inbound messages (from stdin)
for try await line in FileHandle.standardInput.bytes.lines {
    await server.handleLine(line)
}
```

`smallchat channel` does this for you, and reads stdin on its own thread.

## SenderGate

An allowlist of the senders whose events are injected (`senderAllowlist`,
`senderAllowlistFile`). An empty allowlist admits every sender. Pairing codes let a new
sender join: `generatePairingCode(for:)` returns a 6-hex-digit code that expires after
5 minutes, and `completePairing(senderId:code:)` compares it in constant time.

```swift
let gate = await server.getSenderGate()
let code = await gate.generatePairingCode(for: "ci-bot")
// later, when the sender presents the code:
let paired = await gate.completePairing(senderId: "ci-bot", code: code)
```

## ChannelAdapter

Keeps the events the server injected and parses permission requests:

```swift
let adapter = await server.getAdapter()
// The adapter:
// - Records ingested ChannelEvents
// - Parses Claude Code's permission_request params into PermissionRequest
```

Before an event is sent, the server drops `meta` keys that are not identifiers
(letters, digits, `_`), are `__proto__`, `constructor` or `prototype`, or are reserved
(`reservedMetaKeys`: `sender`, `source`, `user`), refuses content over
`maxPayloadSize`, and stamps the event's `sender` as the notification's `meta.sender`.
`serializeChannelTag(channel:content:meta:sender:)` renders a `<channel>` tag with one
`source` (the channel), the `sender` attribute from its argument, and its content
XML-escaped.
