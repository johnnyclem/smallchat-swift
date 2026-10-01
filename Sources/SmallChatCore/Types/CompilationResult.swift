public struct CompilationResult: Sendable {
    public var selectors: [String: ToolSelector]
    public var dispatchTables: [String: [String: any ToolIMP]]
    public var protocols: [ToolProtocolDef]
    public var toolCount: Int
    public var uniqueSelectorCount: Int
    public var mergedCount: Int
    public var collisions: [SelectorCollision]
    public var overloadTables: [String: OverloadTableData]
    public var semanticOverloads: [SemanticOverloadGroup]
    /// Populated by `AppCompiler.compile(_:)` when app manifests are compiled alongside tools.
    public var appArtifact: AppArtifact?
    /// Every compiled tool, in compile order, with its selectors.
    public var tools: [CompiledToolRef]
    /// Distinct tools whose selectors embed at or above the duplicate
    /// threshold (kept only when compiled with `allowDuplicates`).
    public var duplicates: [DuplicateToolPair]

    public init(
        selectors: [String: ToolSelector] = [:],
        dispatchTables: [String: [String: any ToolIMP]] = [:],
        protocols: [ToolProtocolDef] = [],
        toolCount: Int = 0,
        uniqueSelectorCount: Int = 0,
        mergedCount: Int = 0,
        collisions: [SelectorCollision] = [],
        overloadTables: [String: OverloadTableData] = [:],
        semanticOverloads: [SemanticOverloadGroup] = [],
        appArtifact: AppArtifact? = nil,
        tools: [CompiledToolRef] = [],
        duplicates: [DuplicateToolPair] = []
    ) {
        self.selectors = selectors
        self.dispatchTables = dispatchTables
        self.protocols = protocols
        self.toolCount = toolCount
        self.uniqueSelectorCount = uniqueSelectorCount
        self.mergedCount = mergedCount
        self.collisions = collisions
        self.overloadTables = overloadTables
        self.semanticOverloads = semanticOverloads
        self.appArtifact = appArtifact
        self.tools = tools
        self.duplicates = duplicates
    }
}

/// One compiled tool: its canonical id and the selectors that dispatch to it.
public struct CompiledToolRef: Sendable, Equatable {
    /// Canonical tool id `<providerId>/<toolName>`
    public let id: String
    public let providerId: String
    public let toolName: String
    /// Canonical of the tool's primary selector
    public let selector: String
    /// Canonicals of its alias selectors
    public let aliases: [String]

    public init(id: String, providerId: String, toolName: String, selector: String, aliases: [String] = []) {
        self.id = id
        self.providerId = providerId
        self.toolName = toolName
        self.selector = selector
        self.aliases = aliases
    }
}

/// Two distinct tools whose selectors embed at or above the duplicate threshold.
public struct DuplicateToolPair: Sendable, Codable, Equatable {
    public let toolA: String
    public let toolB: String
    public let selectorA: String
    public let selectorB: String
    public let similarity: Double

    public init(toolA: String, toolB: String, selectorA: String, selectorB: String, similarity: Double) {
        self.toolA = toolA
        self.toolB = toolB
        self.selectorA = selectorA
        self.selectorB = selectorB
        self.similarity = similarity
    }
}

public struct SelectorCollision: Sendable, Codable {
    public let selectorA: String
    public let selectorB: String
    public let similarity: Double
    public let hint: String

    public init(
        selectorA: String,
        selectorB: String,
        similarity: Double,
        hint: String
    ) {
        self.selectorA = selectorA
        self.selectorB = selectorB
        self.similarity = similarity
        self.hint = hint
    }
}

public struct OverloadTableData: Sendable, Codable {
    public let selectorCanonical: String
    public let overloads: [OverloadEntryData]

    public init(selectorCanonical: String, overloads: [OverloadEntryData] = []) {
        self.selectorCanonical = selectorCanonical
        self.overloads = overloads
    }
}

public struct OverloadEntryData: Sendable, Codable {
    public let signatureKey: String
    public let parameterNames: [String]
    public let parameterTypes: [String]
    public let arity: Int
    public let toolName: String
    public let providerId: String
    public let isSemanticOverload: Bool

    public init(
        signatureKey: String,
        parameterNames: [String],
        parameterTypes: [String],
        arity: Int,
        toolName: String,
        providerId: String,
        isSemanticOverload: Bool = false
    ) {
        self.signatureKey = signatureKey
        self.parameterNames = parameterNames
        self.parameterTypes = parameterTypes
        self.arity = arity
        self.toolName = toolName
        self.providerId = providerId
        self.isSemanticOverload = isSemanticOverload
    }
}

public struct SemanticOverloadGroup: Sendable {
    public let canonicalSelector: String
    public let tools: [GroupedTool]
    public let reason: String

    public init(canonicalSelector: String, tools: [GroupedTool], reason: String) {
        self.canonicalSelector = canonicalSelector
        self.tools = tools
        self.reason = reason
    }

    public struct GroupedTool: Sendable {
        public let providerId: String
        public let toolName: String
        public let similarity: Double

        public init(providerId: String, toolName: String, similarity: Double) {
            self.providerId = providerId
            self.toolName = toolName
            self.similarity = similarity
        }
    }
}
