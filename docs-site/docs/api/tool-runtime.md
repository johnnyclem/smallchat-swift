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
    var selectorThreshold: Float                    // Default: 0.95 (SelectorTable.intern)
    var cacheSize: Int                              // Default: 1024
    var minConfidence: Double                       // Lowest score the cache stores; default 0.85
    var modelVersion: String?
    var selectorNamespace: SelectorNamespace?
    var rateLimiter: SemanticRateLimiterOptions?    // Opt-in; nil = off
    var dispatchConfig: DispatchConfig              // Tier thresholds and policy guards
    var llmClient: any LLMClient                    // Default: NoOpLLMClient (no verifier)
    var intentPins: [IntentPin]
    var artifactHash: String?                       // Recorded in every proof
}
```

`DispatchConfig` holds `thresholds` (EXACT 0.95, HIGH 0.85, MEDIUM 0.75, LOW 0.60),
`strict`, `requireLLMForSubHighDispatch` (default `true`),
`treatUnannotatedAsDestructive`, `maxDecompositionDepth` and `maxSubDispatches`. See
[Resolution Pipeline](/concepts/resolution-pipeline).

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `selectorTable` | `SelectorTable` | Compiled tool selectors (intents are never added) |
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

## Resolution and Dispatch

### resolve

Decide which tool an intent means. Nothing runs:

```swift
func resolve(_ intent: String, options: ResolveOptions = ResolveOptions()) async throws -> Resolution
```

`Resolution` has `outcome` (`.resolved`, `.needsDisambiguation`, `.unresolved`,
`.throttled`), `tier`, `chosen` (a canonical tool id when resolved), `confidence`,
`candidates`, `reason`, `refinement`, `retryAfterMs` and the `proof`.
`ResolveOptions(learn:args:principal:)`: `learn` consults and updates the resolution
cache, `args` lets overloads and verification see the arguments, `principal` scopes
the rate limiter.

### dispatchById

Run exactly one tool, by canonical id (`<providerId>/<toolName>`), after validating the
arguments against its `inputSchema`:

```swift
func dispatchById(
    _ toolId: String,
    args: [String: any Sendable] = [:],
    options: DispatchByIdOptions = DispatchByIdOptions()
) async throws -> ToolResult
```

`DispatchByIdOptions(resolutionDigest:principal:)`: pass a resolution's
`proof.proofDigest` to link the call to the resolution the user confirmed.

### dispatch (with args)

Resolve an intent (with the cache) and run the chosen tool through `dispatchById`:

```swift
func dispatch(_ intent: String, args: [String: any Sendable], options: DispatchOptions = DispatchOptions()) async throws -> ToolResult
```

When resolution does not settle on one tool, nothing runs: the result is `isError`
with `metadata[DispatchMetadataKey.outcome]` (a `DispatchOutcomeCode` raw value) and a
`ToolRefinement` under `DispatchMetadataKey.refinement`.

**Example:**

```swift
let result = try await runtime.dispatch("search files", args: ["query": "config"])
if result.isError {
    print(result.metadata?[DispatchMetadataKey.outcome] ?? "")
} else {
    print(result.content!)
}
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
    args: [String: any Sendable]? = nil
) -> AsyncThrowingStream<DispatchEvent, Error>

func dispatchStreamById(
    _ toolId: String,
    args: [String: any Sendable] = [:]
) -> AsyncThrowingStream<DispatchEvent, Error>
```

`dispatchStream` resolves first and streams only a resolution the policy allows; a
refused one ends with `.done` carrying the not-executed result.

**Example:**

```swift
for try await event in await runtime.dispatchStream("search", args: ["q": "hello"]) {
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
for try await token in await runtime.inferenceStream("explain", args: ["code": src]) {
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
