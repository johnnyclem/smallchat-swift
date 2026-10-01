---
sidebar_position: 3
title: Your First Dispatch
---

# Your First Dispatch

This walkthrough builds a complete example from scratch: a tool class, a tool, its
selector, then resolving and running intents.

## Create the Runtime

Every smallchat application starts with a `ToolRuntime`:

```swift
import SmallChat

let embedder = LocalEmbedder()
let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: embedder
)
```

The runtime manages the selector table, the resolution cache, and the dispatch
context.

## Create a Tool Implementation

Implement the `ToolIMP` protocol for each tool. Its canonical id is
`<providerId>/<toolName>`, here `flights/search_flights`:

```swift
final class SearchFlightsTool: ToolIMP, @unchecked Sendable {
    let providerId = "flights"
    let toolName = "search_flights"
    let transportType: TransportType = .local
    let annotations: ToolAnnotations? = ToolAnnotations(readOnlyHint: true)
    var schema: ToolSchema? { Self.toolSchema }

    static let toolSchema = ToolSchema(
        name: "search_flights",
        description: "Search for available flights",
        inputSchema: JSONSchemaType(json: [
            "type": .string("object"),
            "properties": .dict([
                "destination": .dict(["type": .string("string")]),
                "date": .dict(["type": .string("string")]),
            ]),
            "required": .array([.string("destination")]),
        ])
    )

    func loadSchema() async throws -> ToolSchema { Self.toolSchema }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        let destination = args["destination"] as? String ?? "unknown"
        return ToolResult(content: "Found 3 flights to \(destination)")
    }
}
```

`annotations` tell the dispatch policy whether a tool is destructive; a read-only tool
never is.

## Register the Selector and the Class

Embed the tool's text, register the selector in the runtime's selector table (so
vector search can find it), and add the method to a class:

```swift
let vector = try await embedder.embed("search_flights: Search for available flights")
let selector = try await runtime.selectorTable.register(embedding: vector, canonical: "flights.search_flights")

let flightTools = ToolClass(name: "flights")
flightTools.addMethod(selector, imp: SearchFlightsTool())
try await runtime.registerClass(flightTools)
```

## Resolve an Intent

`resolve` decides which tool an intent means, and runs nothing:

```swift
let resolution = try await runtime.resolve("search for available flights")
switch resolution.outcome {
case .resolved:
    print("would run \(resolution.chosen!) at tier \(resolution.tier)")
case .needsDisambiguation, .unresolved:
    print("ask the user:", resolution.refinement?.nearMatches.map(\.toolId) ?? [])
case .throttled:
    break
}
```

A match at EXACT (>= 0.95) or HIGH (>= 0.85) similarity resolves. A MEDIUM or LOW match
resolves only when an `LLMClient` verifier approves it; without one, the outcome is
`needs-disambiguation` and the refinement lists the candidates.

## Run a Tool

Run exactly one tool by its id. The arguments are validated against its
`inputSchema` first:

```swift
let result = try await runtime.dispatchById("flights/search_flights", args: ["destination": "Tokyo"])
print(result.content!)
// "Found 3 flights to Tokyo"

let bad = try await runtime.dispatchById("flights/search_flights", args: [:])
// bad.isError == true, outcome "invalid-arguments": missing required argument "destination"
```

Or resolve and run in one call. When resolution doesn't settle on one tool, nothing
runs:

```swift
let byIntent = try await runtime.dispatch("search for available flights", args: ["destination": "Tokyo"])
if byIntent.isError {
    print(byIntent.metadata?[DispatchMetadataKey.outcome] ?? "")   // e.g. "needs-disambiguation"
}
```

## Use the Fluent API

```swift
let result = try await runtime
    .dispatch("search for available flights")
    .withArgs(["destination": "Tokyo", "date": "2025-06-15"])
    .withTimeout(.seconds(10))
    .exec()
```

`execContent()` returns just the content, and throws `DispatchError` when the result
is an error (including "nothing ran").

## Watch Resolution Events

```swift
for try await event in await runtime.dispatchStream("search for available flights", args: ["destination": "NYC"]) {
    switch event {
    case .resolving(let intent):
        print("Resolving: \(intent)")
    case .toolStart(let name, _, let confidence, let selector):
        print("Matched: \(name) via \(selector) (confidence: \(confidence))")
    case .done(let result):
        print("Result: \(result.content ?? "nil")")
    case .error(let message, _):
        print("Error: \(message)")
    default:
        break
    }
}
```

## Using the Compiler Instead

For production use, compile tools from manifests into an artifact and load it:

```swift
let manifests: [ProviderManifest] = [/* flights, hotels, ... */]
let result = try await ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex()).compile(manifests)
let artifact = try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
let toolkit = try await MCPToolkit.make(artifact: artifact)
let resolution = try await toolkit.runtime.resolve("find flights to Tokyo")
```

## Next Steps

- [Semantic Dispatch](/concepts/semantic-dispatch) — How vector resolution works
- [Resolution Pipeline](/concepts/resolution-pipeline) — The full dispatch path
- [Compilation](/guides/compilation) — Compiling from MCP manifests
