---
sidebar_position: 7
title: MCPServer
---

# MCPServer

<span class="module-badge">SmallChatMCP</span>

MCP server over Streamable HTTP (protocol 2025-11-25 and 2025-06-18), built on SwiftNIO. See the [MCP Server guide](/guides/mcp-server) for endpoints and behavior.

```swift
actor MCPServer
```

## Configuration

```swift
struct MCPServerConfig: Sendable {
    let port: Int                    // Default: 3000 (0 = any free port)
    let host: String                 // Default: "127.0.0.1"
    let sourcePath: String           // Manifests or compiled artifact ("" = none)
    let dbPath: String               // Default: "smallchat.db"
    let authToken: String?           // Bearer token; nil = no auth
    let enableRateLimit: Bool        // Default: false
    let rateLimitRPM: Int            // Default: 600
    let enableAudit: Bool            // Default: false
    let auditKey: Data?              // Audit chain key; nil = random per server
    let sessionTTLMs: Int            // Default: 86_400_000 (24h)
    let corsOrigin: String           // Default: "http://127.0.0.1"
    let allowedOrigins: [String]     // Extra accepted Origin values
    let maxConnections: Int          // Default: 1000 (0 = unlimited)
    let maxRequestBodyBytes: Int     // Default: 1 MiB
    let shutdownDrainSeconds: Int    // Default: 30
    let toolNaming: MCPToolNaming    // .aggregate or .provider(id)
    let semanticDispatch: Bool       // List smallchat_dispatch; default false

    static func generateAuthToken() -> String
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
| `audit` | `AuditLog` | In-memory, HMAC-chained request log |
| `serverMetrics` | `ServerMetrics` | Request and connection counters |
| `boundPort` | `Int?` | The listening port, once started |
| `toolCatalog` | `MCPToolCatalog?` | The tools `tools/list` serves |

## Tools

```swift
func setArtifact(_ artifact: SerializedArtifact) async
func setToolExecutor(_ executor: @escaping MCPToolExecutor) async
func setRuntime(_ runtime: ToolRuntime, semanticDispatch: Bool = false) async
```

`tools/call` runs exactly the listed tool through the executor (or, with `setRuntime`, the runtime's implementation of that provider's tool). `MCPToolkit.load(source:)` builds such a runtime from manifests or an artifact; `start()` does this itself when `sourcePath` is set.

## Lifecycle

```swift
func start() async throws
func stop() async throws   // drains in-flight requests, then closes connections
```

## Example

```swift
import SmallChatMCP

let server = try MCPServer(config: MCPServerConfig(
    port: 3001,
    sourcePath: "./manifests",
    dbPath: "data/smallchat.db",
    authToken: MCPServerConfig.generateAuthToken(),
    enableRateLimit: true,
    enableAudit: true
))
try await server.start()

// Listening on http://127.0.0.1:3001
// - POST/DELETE /mcp → MCP (Streamable HTTP)
// - GET /health      → Health check
// - GET /metrics     → Counters

try await server.stop()
```

## Supporting Types

### SessionStore

SQLite-backed sessions, created by `initialize` and validated on every later request. Expired sessions are closed.

### RateLimiter

Sliding-window limiter, keyed by client address. Requests over the limit get HTTP `429`.

### AuditLog

```swift
AuditLog(maxEntries: 10_000, hmacKey: key)   // the key is required
```

Every field of each entry is covered by an HMAC-SHA256 chain; `verifyChain()` checks the retained entries (also after eviction). In memory only.
