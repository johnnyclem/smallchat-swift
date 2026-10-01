---
sidebar_position: 5
title: Transport Layer
---

# Transport Layer

The `SmallChatTransport` module provides a pluggable transport system for tool execution
over different protocols. The [Transport API reference](../api/transport) lists every
type and option.

## Transport Protocol

All transports implement the `Transport` protocol. Only `id` and `execute` are required;
the rest have defaults.

```swift
protocol Transport: Sendable {
    var id: String { get }
    var transportType: TransportType? { get }
    var isConnected: Bool { get async }

    func execute(input: TransportInput) async throws -> TransportOutput
    func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error>
    func connect() async throws
    func disconnect() async throws
}
```

A `TransportInput` names the tool (`toolName`) and carries its arguments (`args`, a
`[String: AnySendable]`); a `TransportOutput` carries the status code, headers, body and
metadata, with `isError` set for HTTP errors and transport failures.

## Built-in Transports

### HTTP Transport

JSON over HTTP, with routes for tools that need a specific method or path:

```swift
let transport = HTTPTransport(config: TransportConfig(
    baseURL: URL(string: "https://api.example.com")!,
    headers: ["X-Client": "smallchat"]
))
await transport.addRoute(HTTPTransportRoute(toolName: "search", method: .GET, path: "/search"))

let output = try await transport.execute(input: TransportInput(
    toolName: "search",
    args: ["q": AnySendable("hello")]
))
// GET https://api.example.com/search?q=hello
```

Path placeholders (`/pets/{petId}`) are filled from the arguments and percent-encoded;
a placeholder without an argument fails the call before anything is sent.

### MCP Stdio Transport

Spawn an MCP server and communicate over its stdin and stdout (macOS and Linux; iOS
cannot spawn processes):

```swift
let transport = MCPStdioTransport(config: MCPStdioConfig(
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
))

try await transport.connect()   // the child process is running and initialized
let output = try await transport.execute(input: TransportInput(
    toolName: "list_directory",
    args: ["path": AnySendable("/tmp")]
))
```

### MCP over HTTP

`MCPClientTransport` (in `SmallChatMCP`) is the Streamable HTTP client: it initializes
lazily, keeps the `Mcp-Session-Id`, sends `MCP-Protocol-Version`, and reads answers sent
as JSON or SSE. `MCPSSETransport` posts `tools/call` requests and reads JSON or SSE
answers without managing a session.

### Local Transport

In-process handlers (no network):

```swift
let transport = LocalTransport()
await transport.registerHandler(toolName: "echo") { input in
    TransportOutput(body: Data("result".utf8))
}
```

### RTK Transport

`RtkTransport` wraps another transport: it prefixes eligible shell commands with `rtk`
and pipes response bodies of at least 512 bytes through `rtk filter`, recording what it
did in `TransportOutput.rtkMetadata`. Without the `rtk` binary (and always on iOS) it
passes bodies through.

```swift
let compact = withRtk(transport, config: RtkConfig(filterLevel: .default))
```

## Middleware

`HTTPTransport` applies retry and circuit breaking from its configuration
(`TransportConfig(retryConfig:circuitBreakerConfig:)`). Each middleware can also wrap any
async operation.

### Retry Middleware

Exponential backoff with jitter:

```swift
let retry = RetryMiddleware(config: RetryConfig(maxRetries: 3, baseDelay: 1.0, maxDelay: 30.0))
let value = try await retry.execute { attempt in try await fetchSomething() }
```

### Circuit Breaker

Fail fast when a dependency is unhealthy:

```swift
let breaker = CircuitBreaker(
    transportId: "billing-api",
    config: CircuitBreakerConfig(
        failureThreshold: 5,   // open after 5 failures
        resetTimeout: 60       // try again after 60 s
    )
)
```

States:
- **Closed** — normal operation, requests pass through
- **Open** — failures reached the threshold; calls fail at once with `TransportError.circuitOpen`
- **Half-Open** — after the reset timeout, calls are let through to test recovery

### Timeout Middleware

Enforce request deadlines:

```swift
let timeout = TimeoutMiddleware(timeout: 30)   // seconds
let value = try await timeout.execute { try await fetchSomething() }
```

The deadline holds even when the operation ignores cancellation.

## Authentication

### Bearer Token

```swift
let auth = BearerTokenAuth(token: "sk-...")
```

### OAuth 2.0 client credentials

For APIs behind an OAuth server (this authenticates outbound requests; the MCP server
itself accepts only a bearer token):

```swift
let auth = OAuth2Auth(
    clientId: "my-client",
    clientSecret: "secret",
    tokenURL: URL(string: "https://auth.example.com/token")!,
    scopes: ["tools:read", "tools:execute"]
)
```

## Streaming Parsers

Both parse an `AsyncSequence` of bytes.

### SSE Parser

```swift
for try await event in SSEParser(source: bytes) {
    print(event.data)
}
```

### NDJSON Parser

```swift
for try await line in NDJSONParser(source: bytes) {
    print(String(decoding: line, as: UTF8.self))
}
```

## Importers

### OpenAPI Importer

Convert an OpenAPI spec into tool definitions, and into routes for an `HTTPTransport`:

```swift
let spec = try JSONDecoder().decode(OpenAPIImporter.OpenAPISpec.self, from: openAPIData)
let tools = OpenAPIImporter.toToolDefinitions(from: spec)
let generated = OpenAPIImporter.generateConfig(from: spec)   // baseURL, routes, auth
```

### Postman Importer

```swift
let collection = try PostmanImporter.parse(postmanJSON)
let tools = PostmanImporter.toToolDefinitions(from: collection)
```

## Custom Transports

Implement the `Transport` protocol:

```swift
actor MyTransport: Transport {
    nonisolated let id = "my-transport"

    func execute(input: TransportInput) async throws -> TransportOutput {
        // Your implementation
        TransportOutput(body: Data("{}".utf8))
    }

    func connect() async throws {
        // Establish connection
    }

    func disconnect() async throws {
        // Clean up
    }
}
```
