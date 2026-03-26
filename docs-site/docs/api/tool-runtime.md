---
sidebar_position: 1
title: ToolRuntime
---

# ToolRuntime

<span class="module-badge">SmallChatRuntime</span>

The top-level runtime actor that manages tool registration, dispatch, caching, and version management.

```swift
actor ToolRuntime
```

## Initialization

```swift
init(
    vectorIndex: VectorIndex,
    embedder: Embedder,
    options: RuntimeOptions = RuntimeOptions()
)
```

### RuntimeOptions

```swift
struct RuntimeOptions: Sendable {
    var selectorThreshold: Float    // Default: 0.95
    var cacheSize: Int              // Default: 1024
    var minConfidence: Double       // Default: 0.85
    var modelVersion: String?
    var selectorNamespace: SelectorNamespace?
    var rateLimiter: SemanticRateLimiterOptions?
}
```

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `selectorTable` | `SelectorTable` | Interning table for semantic selectors |
| `cache` | `ResolutionCache` | LRU resolution cache |
| `context` | `DispatchContext` | Runtime dispatch environment |
| `selectorNamespace` | `SelectorNamespace` | Core selector protection |

## Class Registration

### registerClass

Register a tool class for dispatch:

```swift
func registerClass(_ toolClass: ToolClass) async throws
```

### registerCoreClass

Register a protected core class (selectors can't be shadowed):

```swift
func registerCoreClass(_ toolClass: ToolClass, swizzlable: Bool = false) async throws
```

### registerProtocol

Register a protocol definition:

```swift
func registerProtocol(_ proto: ToolProtocolDef) async
```

### loadCategory

Load a category (extension) onto an existing tool class:

```swift
func loadCategory(_ category: ToolCategory) async throws
```

### addOverload

Add an overloaded method to a tool class:

```swift
func addOverload(
    _ toolClass: ToolClass,
    selector: ToolSelector,
    signature: SCMethodSignature,
    imp: ToolIMP,
    originalToolName: String?,
    isSemanticOverload: Bool
) async throws
```

### swizzle

Replace a method implementation (for testing/hot-reload):

```swift
func swizzle(
    _ toolClass: ToolClass,
    selector: ToolSelector,
    newImp: ToolIMP
) async throws -> (any ToolIMP)?
```

Returns the previous implementation, or `nil` if no method existed for that selector.

## Dispatch

### dispatch (with args)

Dispatch an intent with arguments, returning a result:

```swift
func dispatch(_ intent: String, args: [String: any Sendable]) async throws -> ToolResult
```

**Example:**

```swift
let result = try await runtime.dispatch("search files", args: ["query": "config"])
print(result.content!)
```

### dispatch (fluent)

Start a fluent dispatch chain:

```swift
func dispatch(_ intent: String) -> DispatchBuilder<[String: any Sendable]>
```

**Example:**

```swift
let result = try await runtime
    .dispatch("search files")
    .withArgs(["query": "config"])
    .exec()
```

### intent

Start a typed fluent dispatch chain:

```swift
func intent<TArgs: Sendable>(_ intentStr: String) -> DispatchBuilder<TArgs>
```

## Streaming

### dispatchStream

Stream dispatch events for an intent:

```swift
func dispatchStream(
    _ intent: String,
    args: [String: any Sendable]?
) -> AsyncThrowingStream<DispatchEvent, Error>
```

**Example:**

```swift
for try await event in runtime.dispatchStream("search", args: ["q": "hello"]) {
    switch event {
    case .toolStart(let name, _, let confidence, _):
        print("Dispatching to \(name) (\(confidence))")
    case .done(let result):
        print("Result: \(result.content!)")
    default:
        break
    }
}
```

### inferenceStream

Stream individual tokens:

```swift
func inferenceStream(
    _ intent: String,
    args: [String: any Sendable]?
) -> AsyncThrowingStream<String, Error>
```

**Example:**

```swift
for try await token in runtime.inferenceStream("explain", args: ["code": src]) {
    print(token, terminator: "")
}
```

## Version Management

### setProviderVersion

Update a provider's version (invalidates stale cache entries):

```swift
func setProviderVersion(_ providerId: String, _ version: String) async
```

### setModelVersion

Update the model version:

```swift
func setModelVersion(_ version: String) async
```

### updateSchemaFingerprint

Recompute a tool class's schema fingerprint (triggers cache invalidation):

```swift
func updateSchemaFingerprint(_ toolClass: ToolClass) async
```

### invalidateOn

Register a hook that's called when invalidation occurs:

```swift
func invalidateOn(_ hook: @escaping InvalidationHook) async -> Int
```

Returns a hook ID for later removal.

## Header Generation

### generateHeader

Generate a human-readable header describing all registered tools:

```swift
func generateHeader() async -> String
```

Useful for debugging and documentation generation.
