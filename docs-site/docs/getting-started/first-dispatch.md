---
sidebar_position: 3
title: Your First Dispatch
---

# Your First Dispatch

This walkthrough builds a complete example from scratch — registering tool classes, adding methods, and dispatching intents.

## Create the Runtime

Every smallchat application starts with a `ToolRuntime`:

```swift
import SmallChat

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder(),
    options: RuntimeOptions(
        selectorThreshold: 0.95,
        cacheSize: 1024,
        minConfidence: 0.85
    )
)
```

The runtime manages the selector table, resolution cache, and dispatch context.

## Define a Tool Class

A `ToolClass` groups related tools — like a class in object-oriented programming:

```swift
let flightTools = ToolClass(name: "FlightTools")
```

## Create Tool Implementations

Implement the `ToolIMP` protocol for each tool:

```swift
final class SearchFlightsTool: ToolIMP, @unchecked Sendable {
    let providerId = "flights"
    let toolName = "search_flights"
    let transportType: TransportType = .local
    var schema: ToolSchema? = nil

    func loadSchema() async throws -> ToolSchema {
        ToolSchema(
            name: "search_flights",
            description: "Search for available flights",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "destination": .object(["type": .string("string")]),
                    "date": .object(["type": .string("string")])
                ])
            ]
        )
    }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        let destination = args["destination"] as? String ?? "unknown"
        return ToolResult(content: "Found 3 flights to \(destination)")
    }
}
```

## Register and Embed

Create a selector by embedding the intent, then register it:

```swift
// Embed the intent to create a selector
let vector = try await runtime.context.embedder.embed("search flights")
let selector = ToolSelector(
    vector: vector,
    canonical: "search:flights",
    parts: ["search", "flights"],
    arity: 2
)

// Add the method to the tool class
flightTools.addMethod(selector, imp: SearchFlightsTool())

// Register the class with the runtime
try await runtime.registerClass(flightTools)
```

## Dispatch an Intent

Now dispatch a natural language intent:

```swift
let result = try await runtime.dispatch(
    "find available flights",
    args: ["destination": "Tokyo"]
)

print(result.content!)
// "Found 3 flights to Tokyo"
```

The runtime:
1. Embeds `"find available flights"` into a 384-dimensional vector
2. Searches the vector index for similar selectors (cosine similarity > 0.75)
3. Resolves through the dispatch table to `SearchFlightsTool`
4. Executes and returns the result

## Add a Superclass

Tool classes support inheritance. Create a base class for shared behavior:

```swift
let travelTools = ToolClass(name: "TravelTools")
// ... add common travel methods ...

// Set up inheritance
flightTools.superclass = travelTools

// If flightTools can't handle an intent, it traverses up to travelTools
```

## Use the Fluent API

The builder pattern provides a more expressive interface:

```swift
let result = try await runtime
    .dispatch("search flights")
    .withArgs(["destination": "Tokyo", "date": "2025-06-15"])
    .withTimeout(.seconds(10))
    .exec()
```

## Watch Resolution Events

Stream dispatch events for observability:

```swift
for try await event in runtime.dispatchStream("search flights", args: ["destination": "NYC"]) {
    switch event {
    case .resolving(let intent):
        print("🔍 Resolving: \(intent)")
    case .toolStart(let name, let provider, let confidence, let selector):
        print("🎯 Matched: \(name) via \(selector) (confidence: \(confidence))")
    case .done(let result):
        print("✅ Result: \(result.content ?? "nil")")
    case .error(let msg, _):
        print("❌ Error: \(msg)")
    default:
        break
    }
}
```

## Using the Compiler Instead

For production use, you'll typically compile tools from manifests rather than registering them manually:

```swift
let compiler = ToolCompiler(
    embedder: LocalEmbedder(),
    vectorIndex: MemoryVectorIndex()
)

let manifests = [
    ProviderManifest(providerId: "flights", tools: [...]),
    ProviderManifest(providerId: "hotels", tools: [...]),
]

let result = try await compiler.compile(manifests)
let classes = compiler.buildClasses(result)

for toolClass in classes {
    try await runtime.registerClass(toolClass)
}
```

## Next Steps

- [Semantic Dispatch](/concepts/semantic-dispatch) — How vector resolution works
- [Resolution Pipeline](/concepts/resolution-pipeline) — The full dispatch path
- [Compilation](/guides/compilation) — Compiling from MCP manifests
