---
sidebar_position: 3
title: Tool Classes
---

# Tool Classes

A `ToolClass` is the fundamental organizational unit in smallchat — equivalent to a class in Objective-C. It groups related tools with a shared dispatch table, protocol conformance, and superclass chain.

## Creating a Tool Class

```swift
let fileTools = ToolClass(name: "FileTools")
```

## Adding Methods

Methods are added by mapping a `ToolSelector` to a `ToolIMP`. Register the selector
with the runtime's selector table, which also puts its vector in the vector index so
intents can find it (`registerClass` does not index selectors):

```swift
let readSelector = try await runtime.selectorTable.register(
    embedding: try await embedder.embed("read file"),
    canonical: "read:file"
)

fileTools.addMethod(readSelector, imp: ReadFileTool())
```

## Dispatch Table

Each tool class maintains a dispatch table — a dictionary mapping canonical selector strings to tool implementations:

```swift
// Internal structure
dispatchTable: [String: any ToolIMP]
// "read:file"   → ReadFileTool
// "write:file"  → WriteFileTool
// "delete:file" → DeleteFileTool
```

When an intent resolves to a selector, the dispatch table provides O(1) lookup to the implementation.

## Overload Tables

A single selector can have multiple implementations differentiated by argument types:

```swift
try fileTools.addOverload(
    readSelector,
    signature: SCMethodSignature(parameters: [param("path", 0, SCType.string())]),
    imp: ReadByPathTool(),
    originalToolName: "read_by_path"
)

try fileTools.addOverload(
    readSelector,
    signature: SCMethodSignature(parameters: [
        param("path", 0, SCType.string()),
        param("encoding", 1, SCType.string()),
    ]),
    imp: ReadWithEncodingTool(),
    originalToolName: "read_with_encoding"
)
```

Resolution considers argument count and types to pick the best overload. On a
registered class, add overloads with `runtime.addOverload(_:selector:signature:imp:)`,
which also checks protected selectors and flushes the cache. Every overload match is
still judged by the dispatch policy before anything runs.

## Inheritance

Tool classes support single inheritance through a superclass chain:

```swift
let ioTools = ToolClass(name: "IOTools")
// ... add generic I/O methods ...

let fileTools = ToolClass(name: "FileTools")
fileTools.superclass = ioTools
```

When `fileTools` can't resolve a selector, it traverses up to `ioTools`. This mirrors the ISA chain in Objective-C.

## Protocol Conformance

Tool classes can declare protocol conformance. A protocol names the selectors a
conforming class is expected to answer; `conformsTo` reports what the class declared:

```swift
let readableProto = ToolProtocolDef(
    name: "Readable",
    embedding: try await embedder.embed("read"),
    requiredSelectors: [readSelector]
)

fileTools.addProtocol(readableProto)

// Conformance is what the class declared (by protocol name)
fileTools.conformsTo(readableProto) // true
```

## Categories (Extensions)

Extend every registered class that conforms to a protocol with new methods, without
subclassing:

```swift
let compressionCategory = ToolCategory(
    name: "CompressionExtension",
    extendsProtocol: "Readable",
    methods: [
        ToolMethod(selector: compressSelector, imp: CompressFileTool()),
        ToolMethod(selector: decompressSelector, imp: DecompressFileTool()),
    ]
)

try await runtime.loadCategory(compressionCategory)
```

This is the counterpart of an Objective-C category: methods added to existing classes
at runtime. `loadCategory` re-indexes the runtime and flushes the resolution cache, and
throws `SelectorShadowingError` if a method would take over a protected core selector.

## Querying a Tool Class

```swift
// All registered selectors
let selectors = fileTools.allSelectors()
// ["read:file", "write:file", "delete:file"]

// Check if a selector can be handled
fileTools.canHandle(readSelector) // true

// Check for overloads
fileTools.hasOverloads(readSelector) // true if multiple signatures

// Direct resolution
let imp = fileTools.resolveSelector(readSelector)

// Resolution with named arguments (picks best overload)
let result = try fileTools.resolveSelectorWithNamedArgs(
    readSelector,
    namedArgs: ["path": "/tmp/file.txt"]
)
```

## Registration

Tool classes must be registered with the runtime to participate in dispatch:

```swift
// Standard registration
try await runtime.registerClass(fileTools)

// Core class (protected from shadowing)
try await runtime.registerCoreClass(fileTools, swizzlable: false)
```

A core class's selectors are recorded in the runtime's `SelectorNamespace`: another
class's category, overload or swizzle that would take one over throws
`SelectorShadowingError`, unless the core class was registered with `swizzlable: true`.
`registerClass` does not check selectors against the namespace.
