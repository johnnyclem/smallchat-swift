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
1. Generates a canonical selector from the tool name and description
2. Creates a 384-dimensional vector embedding
3. Interns the selector in the `SelectorTable` (deduplicating near-duplicates)
4. Detects potential merges — tools from different providers that should share a selector

### Phase 3: LINK

Builds the dispatch infrastructure:
1. Creates `ToolClass` instances and dispatch tables
2. Detects selector collisions (different tools mapping to the same selector unintentionally)
3. Validates no shadowing of protected namespaces
4. Builds overload tables for tools sharing a selector

### Phase 4: OUTPUT

Serializes the compiled artifact to JSON:
- Embedded vectors for all selectors
- Dispatch table mappings
- Provider metadata
- Version stamps for cache invalidation

## Compiler Options

```swift
let options = CompilerOptions(
    // Minimum cosine similarity to merge two selectors
    deduplicationThreshold: 0.95,

    // Minimum similarity to flag a potential collision
    collisionThreshold: 0.85,

    // Whether to auto-generate semantic overloads
    generateSemanticOverloads: true,

    // Maximum tools per provider (for sanity checking)
    maxToolsPerProvider: 500
)
```

## Building Classes from Results

After compilation, convert the result into runtime-ready tool classes:

```swift
let result = try await compiler.compile(manifests)
let classes = compiler.buildClasses(result)

let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

for toolClass in classes {
    try await runtime.registerClass(toolClass)
}
```

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

The compiled artifact is a JSON file containing:

```json
{
  "version": "0.2.0",
  "compiled_at": "2025-01-15T10:30:00Z",
  "providers": [...],
  "selectors": {
    "search:files": {
      "vector": [0.23, 0.15, ...],
      "canonical": "search:files",
      "arity": 2,
      "dispatch": {
        "provider": "my-tools",
        "tool": "search_files"
      }
    }
  },
  "dispatch_tables": {...},
  "metadata": {...}
}
```
