---
sidebar_position: 6
title: Transport
---

# Transport

<span class="module-badge">SmallChatTransport</span>

Pluggable transport layer for executing tools over HTTP, MCP (stdio or HTTP), or in-process.

## Transport Protocol

```swift
protocol Transport: Sendable {
    var id: String { get }
    var transportType: TransportType? { get }   // default: nil
    var isConnected: Bool { get async }         // default: true

    func execute(input: TransportInput) async throws -> TransportOutput
    func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error>  // default: execute once
    func connect() async throws                 // default: no-op
    func disconnect() async throws              // default: no-op
}
```

## TransportInput

```swift
struct TransportInput: Sendable {
    var toolName: String
    var args: [String: AnySendable]
    var method: HTTPMethod?        // HTTP override
    var url: String?               // HTTP URL or path override
    var headers: [String: String]
    var body: Data?                // pre-serialized body
    var timeout: TimeInterval?     // overrides the transport's timeout
    var stream: Bool
    var metadata: [String: String]
}
```

Every field has a default, so `TransportInput(toolName: "search", args: ["q": AnySendable("hello")])` is enough.

## TransportOutput

```swift
struct TransportOutput: Sendable {
    var statusCode: Int            // 0 for non-HTTP transports
    var headers: [String: String]
    var body: Data?
    var metadata: [String: String]
    var rtkMetadata: RtkMetadata?  // set by RtkTransport

    var isError: Bool              // statusCode >= 400 or metadata["isError"] == "true"
    var bodyString: String?
    func decoded<T: Decodable>(as: T.Type, using: JSONDecoder = JSONDecoder()) throws -> T
}
```

## HTTPTransport

JSON over HTTP. Routes map a tool name to a method and path; `{name}` placeholders are
filled from the arguments (percent-encoded as one path segment), declared `queryParams`
go in the query string, and the remaining arguments go in the JSON body (or in the query
string for GET and HEAD).

```swift
let transport = HTTPTransport(config: TransportConfig(
    baseURL: URL(string: "https://api.example.com")!,
    retryConfig: RetryConfig(maxRetries: 3),
    headers: ["X-Client": "smallchat"],
    auth: BearerTokenAuth(token: "sk-...")
))
await transport.addRoute(HTTPTransportRoute(
    toolName: "get_pet", method: .GET, path: "/pets/{petId}", queryParams: ["verbose"]
))

let output = try await transport.execute(input: TransportInput(
    toolName: "get_pet",
    args: ["petId": AnySendable(42), "verbose": AnySendable(true)]
))
// GET https://api.example.com/pets/42?verbose=true
if output.isError { print(output.metadata["error"] ?? "") }
```

`execute` reports failures as an output with `isError` (a missing placeholder argument
is `TransportError.invalidRequest`, and nothing is sent). `TransportConfig` also takes
`timeout` (seconds, default 30), `circuitBreakerConfig`, `defaultMethod` (default
`.POST`; a tool without a route goes to `<baseURL>/<toolName>`) and `poolSize`.

## MCPStdioTransport

Spawns an MCP server and speaks JSON-RPC over its stdin/stdout (macOS and Linux only).
`execute` calls `tools/call` with the input's tool name and arguments; the client
negotiates the protocol version (it asks for 2025-11-25).

```swift
let transport = MCPStdioTransport(config: MCPStdioConfig(
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
))

try await transport.connect()              // spawns the process and initializes
let tools = try await transport.listTools()
let output = try await transport.execute(input: TransportInput(
    toolName: "read_file",
    args: ["path": AnySendable("/tmp/notes.txt")]
))
try await transport.disconnect()           // terminates the process
```

A call that times out (`TransportInput.timeout`, default 30 s) is cancelled on the
server; a server that exits fails every pending call with its stderr tail.

## MCPSSETransport

Sends JSON-RPC `tools/call` requests as HTTP POSTs and reads the answer as JSON or as
an SSE stream:

```swift
let transport = MCPSSETransport(config: MCPSSEConfig(
    url: URL(string: "http://localhost:3001/mcp")!
))

for try await output in transport.executeStream(input: TransportInput(toolName: "search")) {
    print(output.bodyString ?? "")
}
```

It does not manage MCP sessions. For a Streamable HTTP server that needs `initialize`
and an `Mcp-Session-Id`, use `MCPClientTransport` from `SmallChatMCP`.

## LocalTransport

In-process handlers, no network:

```swift
let transport = LocalTransport()
await transport.registerHandler(toolName: "echo") { input in
    TransportOutput(body: Data("processed: \(input.toolName)".utf8))
}

let output = try await transport.execute(input: TransportInput(toolName: "echo"))
```

`LocalTransport(handler:)` sets a fallback handler for tool names without one of their own.

## Middleware

`HTTPTransport` applies retry and circuit breaking from its `TransportConfig`. The
middleware can also wrap any async operation.

### RetryMiddleware

Exponential backoff with jitter:

```swift
let retry = RetryMiddleware(config: RetryConfig(
    maxRetries: 3,
    baseDelay: 1.0,        // seconds
    maxDelay: 30.0,
    retryableStatusCodes: [408, 429, 500, 502, 503, 504]
))
let value = try await retry.execute { attempt in
    try await fetchSomething()
}
```

### CircuitBreaker

```swift
let breaker = CircuitBreaker(
    transportId: "billing-api",
    config: CircuitBreakerConfig(failureThreshold: 5, resetTimeout: 60)
)
let value = try await breaker.execute { try await fetchSomething() }
// States: .closed → .open → .halfOpen → .closed; when open, execute throws TransportError.circuitOpen
```

### TimeoutMiddleware

```swift
let timeout = TimeoutMiddleware(timeout: 30)   // seconds
let value = try await timeout.execute { try await fetchSomething() }
```

The deadline holds even when the operation ignores cancellation: `withTimeout(seconds:_:)`
returns `TransportError.timeout` at the deadline and cancels the operation.

## Authentication

Auth strategies add credentials to outbound requests (`TransportConfig.auth`,
`MCPSSEConfig.auth`).

### BearerTokenAuth

```swift
let auth = BearerTokenAuth(token: "sk-...")
```

### OAuth2Auth

The OAuth 2.0 client credentials flow, with the token cached until shortly before it expires:

```swift
let auth = OAuth2Auth(
    clientId: "id",
    clientSecret: "secret",
    tokenURL: URL(string: "https://auth.example.com/token")!,
    scopes: ["tools:read"]
)
```

This is a client of someone else's OAuth server; the MCP server itself accepts only a
bearer token.

## Streaming Parsers

Both parse an `AsyncSequence` of bytes (for example the body bytes of a streaming
response).

### SSEParser

```swift
for try await event in SSEParser(source: bytes) {
    print("Event: \(event.event ?? "message")")
    print("Data: \(event.data)")
}
```

### NDJSONParser

```swift
for try await line in NDJSONParser(source: bytes) {
    // Each element is one line's JSON as Data
}
```

## Importers

### OpenAPIImporter

```swift
let spec = try JSONDecoder().decode(OpenAPIImporter.OpenAPISpec.self, from: openAPIData)

// Tool definitions for a manifest
let tools = OpenAPIImporter.toToolDefinitions(from: spec, providerId: "petstore")

// Routes for an HTTPTransport
let generated = OpenAPIImporter.generateConfig(from: spec)
let transport = HTTPTransport(config: TransportConfig(baseURL: URL(string: generated.baseURL)!, auth: generated.auth))
await transport.addRoutes(generated.routes)
```

### PostmanImporter

```swift
let collection = try PostmanImporter.parse(postmanJSON)
let tools = PostmanImporter.toToolDefinitions(from: collection)
let generated = PostmanImporter.importCollection(collection)
```
