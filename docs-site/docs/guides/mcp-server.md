---
sidebar_position: 3
title: MCP Server
---

# MCP Server

smallchat-swift includes an MCP (Model Context Protocol) server over Streamable HTTP, built on SwiftNIO. It negotiates protocol versions 2025-11-25 and 2025-06-18.

## Quick Start

### CLI

```bash
swift run smallchat serve --source ./manifests --port 3001
```

Point an MCP client at `http://127.0.0.1:3001/mcp`. For Claude Code:

```bash
claude mcp add --transport http smallchat http://127.0.0.1:3001/mcp
```

### Programmatic

```swift
import SmallChatMCP

let config = MCPServerConfig(
    port: 3001,
    host: "127.0.0.1",
    sourcePath: "./manifests",   // manifests or a compiled artifact
    dbPath: "smallchat.db"
)

let server = try MCPServer(config: config)
try await server.start()       // loads the toolkit and wires its runtime
```

To serve tools you run yourself, leave `sourcePath` empty and wire them:

```swift
await server.setArtifact(artifact)
await server.setToolExecutor { tool, arguments in
    // tool.providerId, tool.toolName: exactly the tool that was called
    ToolResult(codableContent: .dict(arguments))
}
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp` | POST | One JSON-RPC message. `initialize` opens a session (id in the `Mcp-Session-Id` response header); later requests must send it. Notifications get `202 Accepted`. |
| `/mcp` | DELETE | End the session named by `Mcp-Session-Id` |
| `/mcp` | GET | `405`: the server opens no server-to-client stream |
| `/health` | GET | Status, tool counts, protocol versions (no auth) |
| `/metrics` | GET | Request and connection counters |

Requests without a session get `400`; unknown or expired sessions get `404`. JSON-RPC batches, non-JSON bodies, and unsupported `MCP-Protocol-Version` headers get `400`/`415`.

## Tools

`tools/list` names tools `<providerId>__<toolName>`. With `toolNaming: .provider("github")` (CLI: `--provider github`) the server lists one provider's tools under their upstream names instead.

`tools/call` runs exactly the named tool; an unlisted name is a JSON-RPC `-32602` error and nothing runs. Without a wired runtime or executor, a call is a JSON-RPC error. The result is an MCP `CallToolResult`:

```json
{
  "content": [{ "type": "text", "text": "{\"id\":7}" }],
  "structuredContent": { "id": 7 },
  "isError": false,
  "_meta": { "dev.smallchat/toolId": "github/create_issue" }
}
```

A tool that fails returns `isError: true` with the reason as text.

Where a tool runs: `MCPToolkit` builds a runtime whose tools call their provider manifest's `endpoint` (an MCP Streamable HTTP URL for `transportType: "mcp"`, whose result is passed through; a base URL for `"rest"`, called as `POST <endpoint>/<tool>`). Tools whose provider declares no endpoint are listed but fail when called.

### Semantic dispatch

Semantic intent resolution is not used on `tools/call`. To expose it, enable the `smallchat_dispatch` meta-tool (`semanticDispatch: true`, CLI `--semantic-dispatch`). It takes `{"intent": "...", "arguments": {...}}`, resolves the intent through the tiered dispatch pipeline, and runs the resolved tool only at a confident tier; otherwise it returns a refinement or sub-intents and runs nothing.

## Configuration

```swift
let config = MCPServerConfig(
    port: 3001,                  // Listen port (0 = any free port, see boundPort)
    host: "127.0.0.1",           // Bind address
    sourcePath: "./manifests",   // Toolkit source ("" = set programmatically)
    dbPath: "smallchat.db",      // SQLite database for sessions
    authToken: "secret",         // Require Authorization: Bearer <token>
    enableRateLimit: true,       // Per-client-address rate limiting
    rateLimitRPM: 600,           // Requests per minute
    enableAudit: true,           // In-memory, HMAC-chained audit log
    sessionTTLMs: 86_400_000,    // Session TTL (24h)
    maxConnections: 1000,        // Connections beyond this are closed
    toolNaming: .aggregate,      // or .provider("id")
    semanticDispatch: false      // list smallchat_dispatch
)
```

## Security

- **Host and Origin checks.** A server bound to a loopback address rejects non-loopback `Host` names and foreign `Origin` headers with `403` (DNS rebinding protection).
- **Bearer token.** With `authToken` set, every request except `GET /health` needs `Authorization: Bearer <token>`. `smallchat serve --auth` reads the token from `SMALLCHAT_MCP_TOKEN` or a token file (default `~/.smallchat/serve-token`, created with mode 0600). OAuth is not implemented.
- **Rate limiting** is keyed by the client's address, so a client cannot escape it by choosing new session ids. Over the limit, requests get `429`.
- **Limits.** Bodies over `maxRequestBodyBytes` get `413`; connections beyond `maxConnections` are closed.

## Audit Logging

With `enableAudit`, each request is recorded (method, session, client address, outcome, duration, error) in an in-memory `AuditLog`. Entries form an HMAC-SHA256 chain under `auditKey` (a random key per server when not set): editing a retained entry without the key breaks `verifyChain()`. The log does not survive a restart.

## Not implemented

Server-to-client SSE streams (so no `list_changed` or resource subscription notifications), JSON-RPC batches, MCP logging, and OAuth. Adopting the official MCP Swift SDK is planned for a 1.x release.

## Registries

### Resource Registry

```swift
let resources = await server.resources
// Resources are available via resources/list and resources/read
```

### Prompt Registry

```swift
let prompts = await server.prompts
// Prompts are available via prompts/list and prompts/get
```
