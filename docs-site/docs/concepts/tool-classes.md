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

Methods are added by mapping a `ToolSelector` to a `ToolIMP`:

```swift
let readSelector = ToolSelector(
    vector: try await embedder.embed("read file"),
    canonical: "read:file",
    parts: ["read", "file"],
    arity: 2
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
    signature: SCMethodSignature(params: [.init(name: "path", type: .string)]),
    imp: ReadByPathTool(),
    originalToolName: "read_by_path",
    isSemanticOverload: false
)

try fileTools.addOverload(
    readSelector,
    signature: SCMethodSignature(params: [
        .init(name: "path", type: .string),
        .init(name: "encoding", type: .string),
    ]),
    imp: ReadWithEncodingTool(),
    originalToolName: "read_with_encoding",
    isSemanticOverload: false
)
```

Resolution considers argument count and types to pick the best overload.

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

Tool classes can declare protocol conformance:

```swift
let streamableProto = ToolProtocolDef(name: "Streamable", requiredSelectors: ["stream:output"])

fileTools.addProtocol(streamableProto)

// Check conformance
fileTools.conformsTo(streamableProto) // true
```

## Categories (Extensions)

Extend existing tool classes with new methods without subclassing:

```swift
let compressionCategory = ToolCategory(
    name: "CompressionExtension",
    targetClass: "FileTools",
    methods: [
        (compressSelector, CompressFileTool()),
        (decompressSelector, DecompressFileTool()),
    ]
)

try await runtime.loadCategory(compressionCategory)
```

This is equivalent to Objective-C categories — adding methods to an existing class at runtime.

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

Core classes have their selectors protected by the `SelectorNamespace`, preventing plugins from overriding critical system tools.
