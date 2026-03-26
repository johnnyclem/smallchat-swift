---
sidebar_position: 7
title: MCPServer
---

# MCPServer

<span class="module-badge">SmallChatMCP</span>

Production-ready MCP 2024-11-05 protocol server built on SwiftNIO.

```swift
actor MCPServer
```

## Configuration

```swift
struct MCPServerConfig: Sendable {
    var port: Int                // Default: 3000
    var host: String             // Default: "127.0.0.1"
    var sourcePath: String       // Tool manifest source path
    var dbPath: String           // Default: "smallchat.db"
    var enableAuth: Bool         // Default: false
    var enableRateLimit: Bool    // Default: false
    var rateLimitRPM: Int        // Default: 600
    var enableAudit: Bool        // Default: false
    var sessionTTLMs: Int        // Default: 86_400_000 (24h)
}
```

## Initialization

```swift
init(config: MCPServerConfig) throws
```

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `resources` | `ResourceRegistry` | MCP resource management |
| `prompts` | `PromptRegistry` | MCP prompt templates |
| `oauth` | `OAuthManager` | OAuth 2.1 authentication |
| `sse` | `SSEBroker` | SSE message broadcasting |
| `audit` | `AuditLog` | Compliance logging |

## Lifecycle

### start

Start the HTTP server:

```swift
func start() async throws
```

### stop

Gracefully shut down:

```swift
func stop() async throws
```

## Request Processing

### processJSONRPC

Handle a JSON-RPC request:

```swift
func processJSONRPC(
    body: String,
    sessionId: String?,
    clientAddress: String?,
    authHeader: String?,
    acceptsSSE: Bool
) async -> (response: JSONRPCResponse?, headers: [String: String])
```

## Discovery & Health

### discoveryDocument

Return the MCP discovery document:

```swift
func discoveryDocument() -> [String: AnyCodableValue]
```

### healthResponse

Return server health status:

```swift
func healthResponse() async -> [String: AnyCodableValue]
```

## Notifications

### broadcastListChanged

Notify connected SSE clients that a resource list changed:

```swift
func broadcastListChanged(type: String) async
```

## Example

```swift
import SmallChatMCP

let config = MCPServerConfig(
    port: 3001,
    host: "127.0.0.1",
    sourcePath: "./manifests",
    dbPath: "data/smallchat.db",
    enableAuth: true,
    enableRateLimit: true,
    rateLimitRPM: 600,
    enableAudit: true,
    sessionTTLMs: 86_400_000
)

let server = try MCPServer(config: config)

// Start serving
try await server.start()

// Server is now listening on http://127.0.0.1:3001
// - POST /          → JSON-RPC 2.0
// - GET /sse        → Server-Sent Events
// - GET /health     → Health check
// - GET /.well-known/mcp.json → Discovery

// Later...
try await server.stop()
```

## Supporting Types

### SessionStore

SQLite-backed session persistence:

```swift
// Sessions are managed automatically by MCPServer
// Persists across restarts, expired sessions cleaned up
```

### RateLimiter

Sliding-window rate limiting:

```swift
// Configured via MCPServerConfig.rateLimitRPM
// Returns HTTP 429 with Retry-After header when exceeded
```

### SSEBroker

Manages per-client SSE channels:

```swift
// Clients connect via GET /sse
// Events are broadcast via broadcastListChanged()
// Automatic cleanup on disconnect
```

### OAuthManager

OAuth 2.1 authentication:

```swift
// Enabled via MCPServerConfig.enableAuth
// Validates Bearer tokens in Authorization header
// Supports client credentials flow
```

### AuditLog

Compliance logging to SQLite:

```swift
// Enabled via MCPServerConfig.enableAudit
// Records all requests, auth events, rate limits
```
