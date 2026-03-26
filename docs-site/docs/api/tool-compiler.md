---
sidebar_position: 4
title: ToolCompiler
---

# ToolCompiler

<span class="module-badge">SmallChatCompiler</span>

Transforms tool manifests into optimized dispatch artifacts through a 4-phase pipeline.

```swift
struct ToolCompiler: Sendable
```

## Initialization

```swift
init(
    embedder: any Embedder,
    vectorIndex: any VectorIndex,
    options: CompilerOptions = CompilerOptions()
)
```

### CompilerOptions

```swift
struct CompilerOptions {
    var deduplicationThreshold: Float   // Default: 0.95
    var collisionThreshold: Float       // Default: 0.85
    var generateSemanticOverloads: Bool  // Default: true
    var maxToolsPerProvider: Int         // Default: 500
}
```

## Methods

### compile

Run the full 4-phase compilation pipeline:

```swift
func compile(_ manifests: [ProviderManifest]) async throws -> CompilationResult
```

The four phases:
1. **PARSE** — Extract tool definitions from manifests
2. **EMBED** — Generate vectors, intern selectors
3. **LINK** — Build dispatch tables, detect collisions
4. **OUTPUT** — Serialize artifact

### buildClasses

Convert compilation results into runtime-ready `ToolClass` instances:

```swift
func buildClasses(_ result: CompilationResult) -> [ToolClass]
```

## Input Types

### ProviderManifest

```swift
struct ProviderManifest {
    let providerId: String
    let tools: [ToolDefinition]
}
```

### ToolDefinition

```swift
struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodableValue]
}
```

## Example

```swift
import SmallChatCompiler
import SmallChatEmbedding

let compiler = ToolCompiler(
    embedder: LocalEmbedder(),
    vectorIndex: MemoryVectorIndex(),
    options: CompilerOptions(
        deduplicationThreshold: 0.95,
        generateSemanticOverloads: true
    )
)

let manifests = [
    ProviderManifest(
        providerId: "filesystem",
        tools: [
            ToolDefinition(
                name: "read_file",
                description: "Read the contents of a file",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ]
            ),
            ToolDefinition(
                name: "write_file",
                description: "Write content to a file",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "content": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]
            ),
        ]
    ),
]

// Compile
let result = try await compiler.compile(manifests)

// Build runtime classes
let classes = compiler.buildClasses(result)

// Register with runtime
let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

for toolClass in classes {
    try await runtime.registerClass(toolClass)
}

// Now dispatch works
let output = try await runtime.dispatch("read a file", args: ["path": "/tmp/hello.txt"])
```
