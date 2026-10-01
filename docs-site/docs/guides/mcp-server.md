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
  "_meta": {
    "dev.smallchat/toolId": "github/create_issue",
    "dev.smallchat/resolution": { "toolId": "github/create_issue", "ran": "github/create_issue", "outcome": "resolved", "decision": "exact-id", "tier": "exact", "callDigest": "…", "proofDigest": "…", "artifactHash": "…" }
  }
}
```

Arguments are validated against the tool's `inputSchema` before it runs; a call that
fails validation, or a tool that fails, returns `isError: true` with the reason as
text.

Where a tool runs: `MCPToolkit` builds a runtime whose tools call their provider's
remote endpoint (the manifest's `endpoint`, or the artifact's `launch.url`): an MCP
Streamable HTTP URL for `transportType: "mcp"`, whose result is passed through, or a
base URL for `"rest"`, called as `POST <endpoint>/<tool>`. Tools whose provider has no
remote endpoint (none, or a stdio launch command, which `serve` does not start) are
listed but fail when called.

### Resolving an intent: `smallchat_resolve`

Semantic resolution is never used on `tools/call`. The read-only `smallchat_resolve`
meta-tool (listed by default; `resolveTool: false` or CLI `--no-resolve-tool` leaves it
out) takes `{"intent": "...", "args": {...}}` and returns a proposal — `outcome`,
`name`, `toolId`, `tier`, `confidence`, `reason`, up to five `candidates` and the
`proofDigest` — under the same resolution rules as the runtime. It never runs
anything: the client calls the proposed tool by `name`, and that call is an ordinary
`tools/call`.

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
    resolveTool: true            // list the read-only smallchat_resolve
)
```

## Security

- **Host and Origin checks.** A server bound to a loopback address rejects with `403` any `Host` or `Origin` name other than `localhost`, `::1` or a dotted-decimal IPv4 address in 127.0.0.0/8 (DNS rebinding protection). A DNS name is refused even when it resolves to loopback (`127.0.0.1.nip.io`); add an origin you trust to `allowedOrigins`.
- **Bearer token.** With `authToken` set, every request except `GET /health` needs `Authorization: Bearer <token>`. `smallchat serve --auth` reads the token from `SMALLCHAT_MCP_TOKEN` or a token file (default `~/.smallchat/serve-token`, created with mode 0600; refused if group or other users can access it). OAuth is not implemented.
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
