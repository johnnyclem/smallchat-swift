---
sidebar_position: 3
title: ToolClass
---

# ToolClass

<span class="module-badge">SmallChatCore</span>

Groups related tools with a dispatch table, overload tables, protocol conformance, and superclass chain.

```swift
final class ToolClass: @unchecked Sendable
```

## Initialization

```swift
init(name: String)
```

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `name` | `String` | Class name |
| `protocols` | `[ToolProtocolDef]` | Conformed protocols |
| `dispatchTable` | `[String: any ToolIMP]` | Selector → implementation mapping |
| `overloadTables` | `[String: OverloadTable]` | Selector → overload table |
| `superclass` | `ToolClass?` | Parent class for ISA chain traversal |

## Methods

### addMethod

Add a method to the dispatch table:

```swift
func addMethod(_ selector: ToolSelector, imp: any ToolIMP)
```

### addOverload

Add an overloaded method for a selector:

```swift
func addOverload(
    _ selector: ToolSelector,
    signature: SCMethodSignature,
    imp: any ToolIMP,
    originalToolName: String?,
    isSemanticOverload: Bool
) throws
```

### addProtocol

Declare protocol conformance:

```swift
func addProtocol(_ proto: ToolProtocolDef)
```

### conformsTo

Check protocol conformance:

```swift
func conformsTo(_ proto: ToolProtocolDef) -> Bool
```

## Resolution

### resolveSelector

Look up a selector in the dispatch table:

```swift
func resolveSelector(_ selector: ToolSelector) -> (any ToolIMP)?
```

Returns `nil` if no method is registered for the selector.

### resolveSelectorWithArgs

Resolve with positional arguments (picks best overload):

```swift
func resolveSelectorWithArgs(
    _ selector: ToolSelector,
    args: [any Sendable]
) throws -> OverloadResolutionResult?
```

### resolveSelectorWithNamedArgs

Resolve with named arguments:

```swift
func resolveSelectorWithNamedArgs(
    _ selector: ToolSelector,
    namedArgs: [String: any Sendable]
) throws -> OverloadResolutionResult?
```

### validateAndResolveSelectorWithArgs

Resolve with positional args and validate types:

```swift
func validateAndResolveSelectorWithArgs(
    _ selector: ToolSelector,
    args: [any Sendable]
) throws -> OverloadResolutionResult?
```

Throws `SignatureValidationError` on type mismatch.

### validateAndResolveSelectorWithNamedArgs

Resolve with named args and validate types:

```swift
func validateAndResolveSelectorWithNamedArgs(
    _ selector: ToolSelector,
    namedArgs: [String: any Sendable]
) throws -> OverloadResolutionResult?
```

## Queries

### canHandle

Check if this class (or its superclasses) can handle a selector:

```swift
func canHandle(_ selector: ToolSelector) -> Bool
```

### hasOverloads

Check if a selector has multiple overloaded implementations:

```swift
func hasOverloads(_ selector: ToolSelector) -> Bool
```

### allSelectors

List all registered selector canonical names:

```swift
func allSelectors() -> [String]
```

## Inheritance Example

```swift
let baseTools = ToolClass(name: "BaseTools")
baseTools.addMethod(helpSelector, imp: HelpTool())

let fileTools = ToolClass(name: "FileTools")
fileTools.superclass = baseTools
fileTools.addMethod(readSelector, imp: ReadFileTool())

// fileTools can handle both "read:file" and "help"
fileTools.canHandle(readSelector) // true
fileTools.canHandle(helpSelector) // true (via superclass)
```

## Overload Example

```swift
let tools = ToolClass(name: "SearchTools")

// Base method
tools.addMethod(searchSelector, imp: BasicSearchTool())

// Overload with more specific signature
try tools.addOverload(
    searchSelector,
    signature: SCMethodSignature(params: [
        .init(name: "query", type: .string),
        .init(name: "language", type: .string),
    ]),
    imp: CodeSearchTool(),
    originalToolName: "search_code",
    isSemanticOverload: true
)

// Resolution picks the best overload based on arguments
let result = try tools.resolveSelectorWithNamedArgs(
    searchSelector,
    namedArgs: ["query": "func", "language": "swift"]
)
// → CodeSearchTool (matches both params)
```
