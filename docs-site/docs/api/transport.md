---
sidebar_position: 6
title: Transport
---

# Transport

<span class="module-badge">SmallChatTransport</span>

Pluggable transport layer for executing tools over HTTP, stdio, SSE, or in-process.

## Transport Protocol

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

## TransportInput

```swift
struct TransportInput: Sendable {
    let method: String
    let params: [String: any Sendable]?
}
```

## TransportOutput

```swift
struct TransportOutput: Sendable {
    let content: (any Sendable)?
    let metadata: [String: any Sendable]?
}
```

## HTTPTransport

JSON over HTTP:

```swift
let transport = HTTPTransport(config: TransportConfig(
    baseURL: "https://api.example.com",
    headers: ["Authorization": "Bearer sk-..."]
))

try await transport.connect()
let output = try await transport.execute(input: TransportInput(
    method: "tools/call",
    params: ["name": "search", "arguments": ["q": "hello"]]
))
try await transport.disconnect()
```

## MCPStdioTransport

Spawn a child process and communicate via stdio:

```swift
let transport = MCPStdioTransport(config: TransportConfig(
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
))

try await transport.connect()  // Spawns the process
let output = try await transport.execute(input: TransportInput(
    method: "tools/list",
    params: nil
))
try await transport.disconnect()  // Terminates the process
```

## MCPSSETransport

Server-Sent Events for streaming:

```swift
let transport = MCPSSETransport(config: TransportConfig(
    baseURL: "http://localhost:3001"
))

try await transport.connect()
for try await output in transport.executeStream(input: input) {
    print(output.content!)
}
```

## LocalTransport

In-process function calls:

```swift
let transport = LocalTransport { input in
    TransportOutput(content: "processed: \(input.method)")
}

let output = try await transport.execute(input: TransportInput(
    method: "my-tool",
    params: ["key": "value"]
))
```

## Middleware

### RetryMiddleware

```swift
let retry = RetryMiddleware(
    maxRetries: 3,
    baseDelay: .seconds(1),
    maxDelay: .seconds(30),
    retryableErrors: [.timeout, .connectionReset]
)
```

### CircuitBreaker

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    resetTimeout: .seconds(60)
)
// States: .closed → .open → .halfOpen → .closed
```

### TimeoutMiddleware

```swift
let timeout = TimeoutMiddleware(timeout: .seconds(30))
```

## Authentication

### BearerTokenAuth

```swift
let auth = BearerTokenAuth(token: "sk-...")
```

### OAuth2Auth

```swift
let auth = OAuth2Auth(
    clientId: "id",
    clientSecret: "secret",
    tokenEndpoint: "https://auth.example.com/token",
    scopes: ["tools:read"]
)
```

## Streaming Parsers

### SSEParser

```swift
let parser = SSEParser()
for try await event in parser.parse(byteStream) {
    print("Event: \(event.event ?? "message")")
    print("Data: \(event.data)")
}
```

### NDJSONParser

```swift
let parser = NDJSONParser()
for try await json in parser.parse(byteStream) {
    // Each line is a JSON object
}
```

## Importers

### OpenAPIImporter

```swift
let importer = OpenAPIImporter()
let tools = try importer.importSpec(from: openAPIJSON)
// Returns [ToolDefinition]
```

### PostmanImporter

```swift
let importer = PostmanImporter()
let tools = try importer.importCollection(from: postmanJSON)
```
