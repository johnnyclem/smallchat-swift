---
sidebar_position: 4
title: ToolCompiler
---

# ToolCompiler

<span class="module-badge">SmallChatCompiler</span>

Compiles provider manifests into selectors and dispatch tables, with the same
semantics as @smallchat/core 1.0's compiler. `ArtifactV1.build` turns the result into
an artifact of format 1.0.

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
    var collisionThreshold: Double         // Default: 0.89
    var duplicateThreshold: Double         // Default: 0.95
    var allowDuplicates: Bool              // Default: false
    var generateSemanticOverloads: Bool    // Default: false
    var semanticOverloadThreshold: Double  // Default: 0.82
}
```

`deduplicationThreshold` is the deprecated 0.x name of `duplicateThreshold`.

## Methods

### compile

```swift
func compile(_ manifests: [ProviderManifest]) async throws -> CompilationResult
```

1. **PARSE** — read tool definitions and compiler hints; drop excluded tools.
2. **EMBED** — every tool gets its own selector under its exact canonical
   (`<providerId>.<name>`, or the `pinSelector` / provider `namespace` hint). The
   selector embeds `<name>: <description>` plus the tool's selector hint (or its
   provider's `semanticContext`). Each alias is a selector of its own,
   `<canonical>~alias~<alias_with_underscores>`, embedding the alias text.
3. **LINK** — dispatch tables (alias selectors reach the same tool), duplicate
   detection, and collision reports.

Tools are never merged. It throws:

- `DuplicateToolError` when two distinct tools embed at cosine similarity >=
  `duplicateThreshold`, unless `allowDuplicates` (then both are compiled and the pairs
  are listed in `result.duplicates`).
- `SelectorConflictError` when two tools claim one selector (a `pinSelector` or
  namespace clash), one alias phrase, or a provider declares one tool name twice. This
  cannot be waived.

Pairs of selectors between 0.75 and the duplicate threshold are reported in
`result.collisions` with a hint; they are not errors.

### buildClasses

```swift
func buildClasses(_ result: CompilationResult) -> [ToolClass]
```

Groups the compiled tools by provider into `ToolClass` instances.

## Writing and loading artifacts

```swift
let artifact = try ArtifactV1.build(
    result: result,
    manifests: manifests,
    embedder: embedder.fingerprint!     // e.g. hash / smallchat-hash-v1 / 384 dims
)
try artifact.write(to: URL(fileURLWithPath: "tools.toolkit.json"))

let loaded = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: "tools.toolkit.json"))
```

`ArtifactV1.parse` validates the artifact against spec/artifact's schema and rules and
recomputes its content hash; `assertEmbedder(_:)` refuses an embedder whose
fingerprint differs from the one the artifact records. Compiling spec/artifact's
golden manifest with `LocalEmbedder(dimensions: 16)` reproduces its golden artifact,
content hash included (a conformance test checks it).

## Example

```swift
import SmallChat

let readFile = ToolDefinition(
    name: "read_file",
    description: "Read the contents of a file",
    inputSchema: JSONSchemaType(json: [
        "type": .string("object"),
        "properties": .dict(["path": .dict(["type": .string("string")])]),
        "required": .array([.string("path")]),
    ]),
    providerId: "filesystem",
    transportType: .mcp,
    annotations: ToolAnnotations(readOnlyHint: true)
)
let manifests = [
    ProviderManifest(id: "filesystem", name: "Filesystem", tools: [readFile], transportType: .mcp,
                     endpoint: "http://127.0.0.1:4000/mcp"),
]

let embedder = LocalEmbedder()
let result = try await ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex()).compile(manifests)
let artifact = try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)

// A runtime over the artifact (its tools call the provider's endpoint).
let toolkit = try await MCPToolkit.make(artifact: artifact)
let resolution = try await toolkit.runtime.resolve("read a file")
```
