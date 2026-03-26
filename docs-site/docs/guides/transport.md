---
sidebar_position: 5
title: Transport Layer
---

# Transport Layer

The `SmallChatTransport` module provides a pluggable transport system for tool execution over different protocols.

## Transport Protocol

All transports implement the `Transport` protocol:

```swift
protocol Transport: Sendable {
    var id: String { get }
    var isConnected: Bool { get async }

    func execute(input: TransportInput) async throws -> TransportOutput
    func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error>
    func connect() async throws
    func disconnect() async throws
}
```

## Built-in Transports

### HTTP Transport

JSON over HTTP:

```swift
let transport = HTTPTransport(config: TransportConfig(
    baseURL: "https://api.example.com",
    headers: ["Content-Type": "application/json"]
))

try await transport.connect()
let output = try await transport.execute(input: TransportInput(
    method: "tools/call",
    params: ["name": "search", "arguments": ["q": "hello"]]
))
```

### MCP Stdio Transport

Spawn a child process and communicate over stdio:

```swift
let transport = MCPStdioTransport(config: TransportConfig(
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
))

try await transport.connect()
// The child process is now running
```

### MCP SSE Transport

Server-Sent Events for real-time streaming:

```swift
let transport = MCPSSETransport(config: TransportConfig(
    baseURL: "http://localhost:3001"
))

try await transport.connect()
for try await output in transport.executeStream(input: input) {
    print(output.content)
}
```

### Local Transport

In-process function calls (no network):

```swift
let transport = LocalTransport { input in
    // Handle the request directly
    return TransportOutput(content: "result")
}
```

## Middleware

Transports support middleware for cross-cutting concerns.

### Retry Middleware

Exponential backoff with configurable retries:

```swift
let retry = RetryMiddleware(
    maxRetries: 3,
    baseDelay: .seconds(1),
    maxDelay: .seconds(30),
    retryableErrors: [.timeout, .connectionReset]
)
```

### Circuit Breaker

Fail-fast when a transport is unhealthy:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,      // Open after 5 failures
    resetTimeout: .seconds(60) // Try again after 60s
)
```

States:
- **Closed** — Normal operation, requests pass through
- **Open** — Failures exceeded threshold, requests fail immediately
- **Half-Open** — After timeout, allow one request to test recovery

### Timeout Middleware

Enforce request deadlines:

```swift
let timeout = TimeoutMiddleware(
    timeout: .seconds(30)
)
```

## Authentication

### Bearer Token

```swift
let auth = BearerTokenAuth(token: "sk-...")
```

### OAuth 2.0

```swift
let auth = OAuth2Auth(
    clientId: "my-client",
    clientSecret: "secret",
    tokenEndpoint: "https://auth.example.com/token",
    scopes: ["tools:read", "tools:execute"]
)
```

## Streaming Parsers

### SSE Parser

Parses Server-Sent Events format:

```swift
let parser = SSEParser()
for try await event in parser.parse(stream) {
    print(event.data)
}
```

### NDJSON Parser

Parses newline-delimited JSON:

```swift
let parser = NDJSONParser()
for try await json in parser.parse(stream) {
    print(json)
}
```

## Importers

### OpenAPI Importer

Convert OpenAPI specs into tool definitions:

```swift
let importer = OpenAPIImporter()
let tools = try importer.importSpec(from: openAPIJSON)
```

### Postman Importer

Convert Postman collections:

```swift
let importer = PostmanImporter()
let tools = try importer.importCollection(from: postmanJSON)
```

## Custom Transports

Implement the `Transport` protocol:

```swift
final class MyTransport: Transport, @unchecked Sendable {
    let id = "my-transport"

    var isConnected: Bool {
        get async { /* ... */ }
    }

    func execute(input: TransportInput) async throws -> TransportOutput {
        // Your implementation
    }

    func connect() async throws {
        // Establish connection
    }

    func disconnect() async throws {
        // Clean up
    }
}
```
