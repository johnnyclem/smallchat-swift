---
sidebar_position: 4
title: Claude Code Integration
---

# Claude Code Integration

The `SmallChatChannel` module implements a Claude Code *channel*: an MCP server over
stdio that pushes events into a running Claude Code session. On macOS, the
`SmallChatApp` messenger builds on it to chat with your Claude Code sessions.

## Overview

A channel server:
- declares the `claude/channel` capability in `initialize` (and
  `claude/channel/permission` with permission relay)
- delivers each injected event to Claude Code as a `notifications/claude/channel`
  notification (`channel`, `content` and `meta`)
- with two-way mode, lists one tool, the reply tool (`reply` by default), which Claude
  Code calls to answer on the channel; it lists no other tools
- with permission relay, receives Claude Code's permission requests and sends back the
  verdicts you give it
- with the HTTP bridge, accepts events over `POST /event`

It does not dispatch smallchat tools: serve those with [`smallchat serve`](./mcp-server).

## Starting the Channel Server

### CLI

```bash
swift run smallchat channel --name ci --two-way
```

This starts a stdio JSON-RPC server for Claude Code to launch. It exits when Claude Code
closes its stdin. Add `--http-bridge` (with the shared secret in
`SMALLCHAT_CHANNEL_SECRET`) to accept events over HTTP at `POST /event`, and
`--sender-allowlist a,b` to accept events only from those senders. Bridge events are
from the identity the secret authenticates (`--http-bridge-secret-identity`, default
`bridge`), so an allowlist must name it.

### Programmatic

```swift
import SmallChatChannel

let config = ChannelServerConfig(
    channelName: "ci",
    twoWay: true,
    httpBridge: true,
    httpBridgeSecret: secret,
    httpBridgeSecretIdentity: "ci-bot"
)

let server = ChannelServer(config: config)
await server.start()
try await server.startHTTPBridge()
```

Write `server.outboundMessages` to stdout and feed each stdin line to
`server.handleLine(_:)` (see the [ChannelServer API](../api/channel-server)).

## Architecture

```
Claude Code session
      ▲  stdio (JSON-RPC 2.0, MCP)
      │  notifications/claude/channel, tools/call reply, permission requests
┌─────┴──────────────┐
│  ChannelServer      │  initialize, ping, tools/list, tools/call (reply)
│  ┌───────────────┐  │
│  │  SenderGate   │  │  Allowlist of event senders (empty = everyone)
│  └───────────────┘  │
│  ┌───────────────┐  │
│  │ ChannelAdapter│  │  Records events, parses permission requests
│  └───────────────┘  │
└─────▲──────────────┘
      │  injectEvent(_:)
      │
 your code, or the HTTP bridge (POST /event, shared secret)
```

## Injecting Events

```swift
let delivered = await server.injectEvent(ChannelEvent(
    channel: "ci",
    content: "Build 1234 failed on main",
    meta: ["run_id": "1234"],
    sender: "ci-bot"
))
```

`injectEvent` returns `false` (and emits `.senderRejected` or `.payloadTooLarge`) when
the sender gate or the size limit (`maxPayloadSize`, 64 KB by default) refuses the
event. `meta` keys that are not identifiers are dropped.

Over HTTP, the bridge takes the same event as JSON:

```bash
curl -s http://127.0.0.1:3002/event \
  -H "X-Channel-Secret: $SMALLCHAT_CHANNEL_SECRET" \
  -H 'Content-Type: application/json' \
  -d '{"content": "Build 1234 failed on main", "meta": {"run_id": "1234"}}'
```

The event's sender is the identity the secret authenticates (`httpBridgeSecretIdentity`)
and its channel the server's: a `sender` or `channel` in the body is ignored, and `meta`
can't set `sender`, `source` or `user`.

## Sender Gate

The `SenderGate` decides whose events are injected. With an allowlist
(`senderAllowlist`, `senderAllowlistFile`, `--sender-allowlist`), events from anyone
else are refused; with no allowlist, every sender is admitted. New senders can join
with a pairing code (6 hex digits, valid for 5 minutes, compared in constant time).

## Permission Relay

With `permissionRelay: true` (`--permission-relay`), Claude Code's permission requests
arrive as `.permissionRequestReceived` events and wait in
`getPendingPermissions()`. Send the verdict:

```swift
await server.sendPermissionVerdict(PermissionVerdict(requestId: request.requestId, behavior: .allow))
```

`smallchat channel` only logs the requests to stderr; answering them takes code like
the above. Configure a sender allowlist when you enable the relay.

## Events

The server reports what happens on its `events` stream:

```swift
for await event in await server.events {
    switch event {
    case .initialized:
        print("Claude Code connected")
    case .reply(let channel, let message, _):
        print("Reply on \(channel): \(message)")
    case .eventInjected(let event):
        print("Delivered: \(event.content)")
    case .permissionRequestReceived(let request):
        print("Permission requested: \(request.requestId)")
    case .shutdown:
        print("Channel shutting down")
    default:
        break
    }
}
```

## Security Considerations

- **Event content is untrusted text.** Claude Code receives it as channel content;
  `serializeChannelTag` XML-escapes `&`, `<` and `>` so content can't close the
  `<channel>` tag or open a forged one. It can still contain instructions, so treat
  events like any other untrusted input to the model.
- **Gate the senders.** Without an allowlist, any process that can call `injectEvent`
  (or reach the HTTP bridge with the secret) can push events. A bridge event is from the
  secret's identity, whatever its body says.
- **The bridge secret is mandatory** and is compared in constant time. Use it only for
  the bridge: never reuse it as Stenographer's `STENOGRAPHER_NOTARY_SECRET`.
- **Meta keys are filtered** to identifiers, and `__proto__`, `constructor`,
  `prototype`, `sender`, `source` and `user` are dropped; the server stamps `meta.sender`
  itself.
