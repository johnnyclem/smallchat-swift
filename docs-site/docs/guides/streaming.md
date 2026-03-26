---
sidebar_position: 2
title: Streaming
---

# Streaming

smallchat-swift provides three tiers of streaming for real-time output delivery, from token-level inference to event-level dispatch observation.

## Streaming Tiers

### Tier 1: Inference Streaming

Token-by-token output from `InferenceIMP` tools:

```swift
for try await token in runtime.inferenceStream("explain this code", args: ["code": snippet]) {
    print(token, terminator: "")
}
```

This is the highest-fidelity streaming mode, delivering individual tokens as they're generated. Tools must implement the `InferenceIMP` protocol.

### Tier 2: Chunk Streaming

Result chunks from `StreamableIMP` tools:

```swift
for try await event in runtime.dispatchStream("search files", args: ["query": "config"]) {
    if case .chunk(let content, let index) = event {
        print("Chunk \(index): \(content)")
    }
}
```

### Tier 3: Single-Shot

Standard `ToolIMP` tools return a single result, wrapped in a `.done` event:

```swift
for try await event in runtime.dispatchStream("read file", args: ["path": "/tmp/x"]) {
    if case .done(let result) = event {
        print(result.content!)
    }
}
```

## Dispatch Events

The `DispatchEvent` enum provides full observability:

```swift
enum DispatchEvent: Sendable {
    case resolving(intent: String)
    case toolStart(toolName: String, providerId: String,
                   confidence: Double, selector: String)
    case chunk(content: AnyCodableValue, index: Int)
    case inferenceDelta(delta: InferenceDelta, tokenIndex: Int)
    case done(result: ToolResult)
    case error(message: String, metadata: [String: AnyCodableValue]?)
}
```

### Full Event Stream Example

```swift
for try await event in runtime.dispatchStream("find flights", args: ["to": "NYC"]) {
    switch event {
    case .resolving(let intent):
        // Resolution started
        statusBar.show("Resolving \(intent)...")

    case .toolStart(let name, let provider, let confidence, let selector):
        // Tool found, execution starting
        statusBar.show("Running \(name) (confidence: \(confidence))")

    case .chunk(let content, let index):
        // Intermediate result chunk
        outputView.appendChunk(content)

    case .inferenceDelta(let delta, let tokenIndex):
        // Individual token
        outputView.appendToken(delta.text)

    case .done(let result):
        // Execution complete
        outputView.finalize(result)

    case .error(let message, let metadata):
        // Error occurred
        errorView.show(message)
    }
}
```

## Implementing Streaming Tools

### StreamableIMP

Return chunks of results as they become available:

```swift
final class SearchTool: StreamableIMP, @unchecked Sendable {
    let providerId = "search"
    let toolName = "search_files"
    let transportType: TransportType = .local
    var schema: ToolSchema? = nil

    func loadSchema() async throws -> ToolSchema { ... }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        // Fallback single-shot execution
        ToolResult(content: "results...")
    }

    func executeStream(args: [String: any Sendable]) -> AsyncThrowingStream<ToolResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for result in searchResults {
                    continuation.yield(ToolResult(content: result))
                }
                continuation.finish()
            }
        }
    }
}
```

### InferenceIMP

Return individual tokens:

```swift
final class ExplainTool: InferenceIMP, @unchecked Sendable {
    // ... ToolIMP conformance ...

    func executeStream(args: [String: any Sendable]) -> AsyncThrowingStream<ToolResult, Error> {
        // Chunk-level fallback
        ...
    }

    func executeInference(args: [String: any Sendable]) -> AsyncThrowingStream<InferenceDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for token in generateTokens(args) {
                    continuation.yield(InferenceDelta(text: token))
                }
                continuation.finish()
            }
        }
    }
}
```

## Fluent API Streaming

The `DispatchBuilder` provides convenient streaming methods:

```swift
// Event stream
for try await event in runtime.dispatch("search").withArgs(["q": "hello"]).stream() {
    // DispatchEvent values
}

// Token stream (inference tier)
for try await token in runtime.dispatch("explain").withArgs(["code": src]).tokens() {
    print(token, terminator: "")
}

// Collect all chunks into an array
let chunks = try await runtime.dispatch("search").withArgs(["q": "hello"]).collect()
```

## Tier Fallback

The runtime automatically falls back through tiers:

```
InferenceIMP available? → Use executeInference()
         ↓ no
StreamableIMP available? → Use executeStream()
         ↓ no
ToolIMP (always) → Use execute(), wrap in .done
```

This means any `ToolIMP` can be used with the streaming API — it just won't produce intermediate events.
