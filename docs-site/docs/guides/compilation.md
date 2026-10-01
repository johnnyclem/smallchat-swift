---
sidebar_position: 1
title: Compilation
---

# Compilation Guide

The `ToolCompiler` transforms tool manifests into optimized dispatch artifacts through a 4-phase pipeline.

## Sources

The compiler accepts tools from several sources:

### MCP Configuration

Point at your `~/.mcp.json` or any MCP config file:

```bash
swift run smallchat compile --source ~/.mcp.json
```

### Manifest Directory

A directory of JSON tool manifest files:

```bash
swift run smallchat compile --source ./manifests/
```

### Programmatic

```swift
import SmallChatCompiler

let compiler = ToolCompiler(
    embedder: LocalEmbedder(),
    vectorIndex: MemoryVectorIndex(),
    options: CompilerOptions()
)

let manifests = [
    ProviderManifest(
        providerId: "my-tools",
        tools: [
            ToolDefinition(
                name: "search_files",
                description: "Search for files by name or content",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ])
                ]
            ),
        ]
    ),
]

let result = try await compiler.compile(manifests)
```

## The 4 Phases

### Phase 1: PARSE

Extracts `ToolDefinition` objects from input manifests. Supports:
- MCP tool manifests (JSON)
- OpenAPI specifications (via `OpenAPIImporter`)
- Postman collections (via `PostmanImporter`)
- Raw JSON schemas

### Phase 2: EMBED

For each tool definition:
1. Picks its selector canonical: `<providerId>.<name>`, or the tool's `pinSelector`
   hint, or `<namespace>.<name>` when the provider sets a namespace.
2. Embeds `<name>: <description>`, plus the tool's `selectorHint` (or the provider's
   `semanticContext`), as the selector's vector.
3. Registers the selector under that exact canonical. Tools are never merged: two
   distinct tools always get two selectors.
4. Gives each alias its own selector, `<canonical>~alias~<alias_with_underscores>`,
   embedding the alias text.

### Phase 3: LINK

1. Builds dispatch tables (alias selectors reach the same tool).
2. Duplicate detection: two distinct tools whose selectors embed at cosine similarity
   >= `duplicateThreshold` (0.95) fail the compile with `DuplicateToolError`, unless
   `allowDuplicates`.
3. Collision reports: selector pairs between 0.75 and the duplicate threshold are
   listed with a hint (not errors; `compile --strict` makes them errors).
4. Overload tables when semantic overloads are on.

Two tools claiming one selector, one alias phrase, or one tool name fail with
`SelectorConflictError`.

### Phase 4: OUTPUT

`ArtifactV1.build(result:manifests:embedder:)` writes artifact format 1.0 (below).

## Compiler Options

```swift
let options = CompilerOptions(
    // Similarity above which distinct tools are reported as colliding
    collisionThreshold: 0.89,

    // Distinct tools at or above this similarity are duplicates (a compile error)
    duplicateThreshold: 0.95,

    // Keep duplicates (listed in result.duplicates) instead of failing
    allowDuplicates: false,

    // Group semantically similar tools as overloads of one selector
    generateSemanticOverloads: false
)
```

## Running a compiled toolkit

```swift
let artifact = try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
let toolkit = try await MCPToolkit.make(artifact: artifact)   // or MCPToolkit.load(source:)
let resolution = try await toolkit.runtime.resolve("read a file")
```

`MCPToolkit` refuses an artifact whose embedder fingerprint differs from its
embedder's (`EmbedderMismatchError`).

## Semantic Overload Generation

When `generateSemanticOverloads` is enabled, the compiler groups semantically similar tools as overloads of a shared selector. For example:

```
search_files(query: String)           ┐
search_code(query: String, lang: String) ├→ selector "search" with 3 overloads
search_docs(query: String, tag: String)  ┘
```

This allows a single intent like "search for X" to dispatch to the best-matching overload based on argument types.

## CLI Usage

```bash
# Basic compilation
swift run smallchat compile --source ~/.mcp.json

# Custom output path
swift run smallchat compile --source ./manifests -o my-tools.toolkit.json

# Inspect the compiled artifact
swift run smallchat inspect tools.toolkit.json

# Generate documentation from artifact
swift run smallchat docs tools.toolkit.json
```

## Artifact Format

The compiled artifact is @smallchat/core's format 1.0 (`spec/artifact` in that
repository, copied to `Tests/Fixtures/spec/artifact`), so the TypeScript and Swift
runtimes read each other's artifacts when they use the same embedder:

```json
{
  "formatVersion": "1.0",
  "embedder": { "kind": "hash", "model": "smallchat-hash-v1", "modelSha256": null,
                "dims": 384, "maxLength": null, "pooling": "none", "normalize": true },
  "providers": {
    "notes": { "id": "notes", "name": "Notes", "transportType": "mcp",
               "launch": { "transport": "stdio", "command": "notes-mcp", "args": ["--stdio"], "env": ["NOTES_TOKEN"] } }
  },
  "tools": {
    "notes/create_note": { "id": "notes/create_note", "providerId": "notes", "name": "create_note",
                           "description": "...", "inputSchema": { ... }, "annotations": { ... }, ... }
  },
  "selectors": {
    "notes.create_note": { "canonical": "notes.create_note", "toolId": "notes/create_note", "kind": "tool", "vector": [ ... ] },
    "notes.create_note~alias~jot_something_down": { "kind": "alias", ... }
  },
  "collisions": [ ... ],
  "duplicates": [],
  "stats": { "toolCount": 2, "selectorCount": 3, "providerCount": 1, "collisionCount": 1, "duplicateCount": 0 },
  "contentHash": "<sha256>"
}
```

Loading validates the file against the schema and the format's rules, recomputes
`contentHash`, and refuses a 0.x artifact (`ArtifactVersionError`): recompile it.
