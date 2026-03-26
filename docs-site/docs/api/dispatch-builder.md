---
sidebar_position: 2
title: DispatchBuilder
---

# DispatchBuilder

<span class="module-badge">SmallChatRuntime</span>

A fluent builder for constructing and executing dispatch operations with type-safe arguments.

```swift
struct DispatchBuilder<TArgs: Sendable>: Sendable
```

## Creating a Builder

Builders are created from the runtime:

```swift
// Untyped args
let builder = runtime.dispatch("search files")

// Typed args
let builder: DispatchBuilder<SearchArgs> = runtime.intent("search files")
```

## Builder Methods

### withArgs

Set the dispatch arguments:

```swift
func withArgs<T: Sendable>(_ args: T) -> DispatchBuilder<T>
```

```swift
let result = try await runtime
    .dispatch("search")
    .withArgs(["query": "hello", "limit": 10])
    .exec()
```

### withTimeout

Set a dispatch timeout:

```swift
func withTimeout(_ duration: Duration) -> DispatchBuilder<TArgs>
```

```swift
let result = try await runtime
    .dispatch("slow operation")
    .withArgs(["input": data])
    .withTimeout(.seconds(30))
    .exec()
```

Throws `DispatchTimeoutError` if the timeout expires.

### withMetadata

Attach metadata to the dispatch:

```swift
func withMetadata(_ meta: [String: AnyCodableValue]) -> DispatchBuilder<TArgs>
```

```swift
let result = try await runtime
    .dispatch("search")
    .withArgs(["q": "hello"])
    .withMetadata(["source": .string("user"), "requestId": .string(UUID().uuidString)])
    .exec()
```

## Execution Methods

### exec

Execute the dispatch and return a `ToolResult`:

```swift
func exec() async throws -> ToolResult
```

### execContent

Execute and cast the result content to a specific type:

```swift
func execContent<T>() async throws -> T
```

```swift
let text: String = try await runtime
    .dispatch("read file")
    .withArgs(["path": "/tmp/hello.txt"])
    .execContent()
```

Throws `DispatchContentCastError` if the content can't be cast to `T`.

### stream

Execute and return a stream of `DispatchEvent` values:

```swift
func stream() -> AsyncThrowingStream<DispatchEvent, Error>
```

```swift
for try await event in runtime.dispatch("search").withArgs(["q": "hello"]).stream() {
    // Handle events
}
```

### inferStream / tokens

Execute and return a stream of inference tokens:

```swift
func inferStream() -> AsyncThrowingStream<String, Error>
func tokens() -> AsyncThrowingStream<String, Error>  // alias
```

```swift
for try await token in runtime.dispatch("explain").withArgs(["code": src]).tokens() {
    print(token, terminator: "")
}
```

### collect

Execute a streaming dispatch and collect all chunks into an array:

```swift
func collect() async throws -> [AnyCodableValue]
```

```swift
let chunks = try await runtime
    .dispatch("search")
    .withArgs(["q": "hello"])
    .collect()
```

## Error Types

### DispatchTimeoutError

```swift
struct DispatchTimeoutError: Error, Sendable {
    let intent: String
    let timeoutNs: UInt64
}
```

### DispatchContentCastError

```swift
struct DispatchContentCastError: Error, Sendable {
    let intent: String
    let expectedType: String
}
```

### DispatchStreamError

```swift
struct DispatchStreamError: Error, Sendable {
    let message: String
}
```

## Complete Example

```swift
import SmallChat

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

// Register tools...

// Fluent dispatch with full options
do {
    let result = try await runtime
        .dispatch("search for documents")
        .withArgs(["query": "architecture", "limit": 10])
        .withTimeout(.seconds(15))
        .withMetadata(["requestId": .string(UUID().uuidString)])
        .exec()

    if result.isError {
        print("Tool error: \(result.content!)")
    } else {
        print("Found: \(result.content!)")
    }
} catch let error as DispatchTimeoutError {
    print("Timed out dispatching '\(error.intent)'")
} catch {
    print("Dispatch failed: \(error)")
}
```
