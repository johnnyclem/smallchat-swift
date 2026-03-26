---
sidebar_position: 3
title: MCP Server
---

# MCP Server

smallchat-swift includes a production-ready MCP (Model Context Protocol) 2024-11-05 server built on SwiftNIO.

## Quick Start

### CLI

```bash
swift run smallchat serve --source ./manifests --port 3001
```

### Programmatic

```swift
import SmallChatMCP

let config = MCPServerConfig(
    port: 3001,
    host: "127.0.0.1",
    sourcePath: "./manifests",
    dbPath: "smallchat.db"
)

let server = try MCPServer(config: config)
try await server.start()
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | POST | JSON-RPC 2.0 request handler |
| `/sse` | GET | Server-Sent Events stream |
| `/health` | GET | Health check |
| `/.well-known/mcp.json` | GET | MCP discovery document |

## Configuration

```swift
let config = MCPServerConfig(
    port: 3001,                  // Listen port
    host: "127.0.0.1",          // Bind address
    sourcePath: "./manifests",   // Tool manifest source
    dbPath: "smallchat.db",      // SQLite database path
    enableAuth: true,            // Enable OAuth 2.1
    enableRateLimit: true,       // Enable rate limiting
    rateLimitRPM: 600,           // Requests per minute
    enableAudit: true,           // Enable audit logging
    sessionTTLMs: 86_400_000     // Session TTL (24h)
)
```

## JSON-RPC Methods

The server implements the MCP 2024-11-05 specification:

### `initialize`

Establish a session and negotiate capabilities:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "my-client", "version": "1.0" }
  }
}
```

### `tools/list`

List available tools:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
```

### `tools/call`

Execute a tool:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "search_files",
    "arguments": { "query": "config" }
  }
}
```

### `resources/list` and `resources/read`

List and read server-managed resources via the `ResourceRegistry`.

### `prompts/list` and `prompts/get`

List and retrieve prompt templates via the `PromptRegistry`.

## Server-Sent Events (SSE)

The SSE endpoint provides real-time event streaming:

```bash
curl -N http://localhost:3001/sse
```

Events are delivered via the `SSEBroker`, which manages per-client channels with automatic cleanup on disconnect.

## Authentication

### OAuth 2.1

Enable OAuth for production deployments:

```swift
let config = MCPServerConfig(
    // ...
    enableAuth: true
)
```

The `OAuthManager` handles:
- Token validation
- Scope checking
- Token refresh
- Client credential flows

Requests include the token in the `Authorization` header:

```
Authorization: Bearer <token>
```

## Rate Limiting

The `RateLimiter` implements a sliding-window algorithm:

```swift
let config = MCPServerConfig(
    // ...
    enableRateLimit: true,
    rateLimitRPM: 600  // 600 requests per minute per client
)
```

When exceeded, the server returns HTTP 429 with a `Retry-After` header.

## Session Persistence

Sessions are stored in SQLite via `SessionStore`:

```swift
let config = MCPServerConfig(
    // ...
    dbPath: "smallchat.db",
    sessionTTLMs: 86_400_000  // 24 hours
)
```

Sessions persist across server restarts. Expired sessions are cleaned up automatically.

## Audit Logging

Enable compliance logging:

```swift
let config = MCPServerConfig(
    // ...
    enableAudit: true
)
```

The `AuditLog` records:
- All JSON-RPC requests and responses
- Authentication events
- Rate limit triggers
- Session lifecycle events

Logs are stored in SQLite for queryability.

## Health Check

```bash
curl http://localhost:3001/health
```

Returns server status, uptime, active session count, and tool count.

## Discovery

```bash
curl http://localhost:3001/.well-known/mcp.json
```

Returns the MCP discovery document describing server capabilities, supported protocol version, and available endpoints.

## Registries

### Resource Registry

Register server-managed resources:

```swift
let resources = server.resources
// Resources are available via resources/list and resources/read
```

### Prompt Registry

Register prompt templates:

```swift
let prompts = server.prompts
// Prompts are available via prompts/list and prompts/get
```

## Broadcasting

Notify clients of tool list changes:

```swift
await server.broadcastListChanged(type: "tools")
```

This sends a notification to all connected SSE clients.
