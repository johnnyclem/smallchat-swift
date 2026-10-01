import Foundation

/// SmallChatManifest -- the project-level manifest (`smallchat.json`).
///
/// Analogous to `Package.swift` in SPM or `package.json` in Node.
/// Declares which pre-compiled vendor tool packages to include,
/// compiler options, and output configuration.
public struct SmallChatManifest: Sendable, Codable {
    /// Project name.
    public let name: String
    /// Project version (semver).
    public let version: String
    /// Optional human-readable description.
    public let description: String?
    /// Dependencies -- pre-compiled vendor tool packages.
    /// Keys are package names, values are semver ranges or local paths.
    public let dependencies: [String: String]?
    /// Local manifest directories or files to include in compilation.
    public let manifests: [String]?
    /// Compiler configuration.
    public let compiler: ManifestCompilerConfig?
    /// Output configuration.
    public let output: ManifestOutputConfig?
    /// Provider-level compiler hint overrides, keyed by provider ID.
    public let providerHints: [String: ProviderCompilerHints]?
    /// Tool-level compiler hint overrides, keyed by "providerId.toolName".
    public let toolHints: [String: CompilerHint]?

    public init(
        name: String,
        version: String,
        description: String? = nil,
        dependencies: [String: String]? = nil,
        manifests: [String]? = nil,
        compiler: ManifestCompilerConfig? = nil,
        output: ManifestOutputConfig? = nil,
        providerHints: [String: ProviderCompilerHints]? = nil,
        toolHints: [String: CompilerHint]? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.dependencies = dependencies
        self.manifests = manifests
        self.compiler = compiler
        self.output = output
        self.providerHints = providerHints
        self.toolHints = toolHints
    }
}

/// Compiler configuration within a manifest.
public struct ManifestCompilerConfig: Sendable, Codable {
    /// Embedder type: "onnx" or "hash" ("local" is the 0.x name of "hash").
    public let embedder: String?
    /// Cosine similarity at or above which two distinct tools are a
    /// duplicate (0-1, default 0.95): a compile error unless
    /// `allowDuplicates` is set.
    public let duplicateThreshold: Double?
    /// The 0.x name of `duplicateThreshold` (tools are no longer merged).
    /// Read only when `duplicateThreshold` is absent.
    public let deduplicationThreshold: Double?
    /// Keep near-duplicate tools as a warning instead of a compile error.
    public let allowDuplicates: Bool?
    /// Collision warning threshold (0-1, default 0.89).
    public let collisionThreshold: Double?
    /// Enable semantic overload generation.
    public let generateSemanticOverloads: Bool?
    /// Semantic overload grouping threshold (0-1, default 0.82).
    public let semanticOverloadThreshold: Double?

    public init(
        embedder: String? = nil,
        duplicateThreshold: Double? = nil,
        deduplicationThreshold: Double? = nil,
        allowDuplicates: Bool? = nil,
        collisionThreshold: Double? = nil,
        generateSemanticOverloads: Bool? = nil,
        semanticOverloadThreshold: Double? = nil
    ) {
        self.embedder = embedder
        self.duplicateThreshold = duplicateThreshold
        self.deduplicationThreshold = deduplicationThreshold
        self.allowDuplicates = allowDuplicates
        self.collisionThreshold = collisionThreshold
        self.generateSemanticOverloads = generateSemanticOverloads
        self.semanticOverloadThreshold = semanticOverloadThreshold
    }

    /// `duplicateThreshold`, else the 0.x `deduplicationThreshold`.
    public var effectiveDuplicateThreshold: Double? {
        duplicateThreshold ?? deduplicationThreshold
    }
}

/// Output configuration within a manifest.
public struct ManifestOutputConfig: Sendable, Codable {
    /// Output file path (relative to smallchat.json).
    public let path: String?
    /// Output format: "json" or "sqlite".
    public let format: OutputFormat?
    /// SQLite database path (when format is "sqlite").
    public let dbPath: String?

    public init(
        path: String? = nil,
        format: OutputFormat? = nil,
        dbPath: String? = nil
    ) {
        self.path = path
        self.format = format
        self.dbPath = dbPath
    }

    public enum OutputFormat: String, Sendable, Codable {
        case json
        case sqlite
    }
}

/// Compiler hints for a specific tool.
///
/// Decoding accepts @smallchat/core's spellings too (`pinSelector`,
/// `vendorMeta`) and keeps the hints object verbatim (`json`), which is
/// what artifact format 1.0 records.
public struct CompilerHint: Sendable, Codable, Equatable {
    /// Selector hint override: appended to the text the tool's selector embeds.
    public let selectorHint: String?
    /// Pinned canonical selector (`pinSelector`): the tool's selector name, taken literally.
    public let pinnedSelector: String?
    /// Phrases that resolve to this tool; each gets its own selector.
    public let aliases: [String]?
    /// Priority multiplier. Ignored by dispatch (ranking is by similarity only).
    public let priority: Double?
    /// Mark as preferred for its selector group (collision reports).
    public let preferred: Bool?
    /// Exclude from compilation.
    public let exclude: Bool?
    /// Vendor-specific metadata.
    public let vendorMetadata: [String: String]?
    /// The hints object as decoded (empty when built in code).
    public let json: [String: AnyCodableValue]

    public init(
        selectorHint: String? = nil,
        pinnedSelector: String? = nil,
        aliases: [String]? = nil,
        priority: Double? = nil,
        preferred: Bool? = nil,
        exclude: Bool? = nil,
        vendorMetadata: [String: String]? = nil
    ) {
        self.selectorHint = selectorHint
        self.pinnedSelector = pinnedSelector
        self.aliases = aliases
        self.priority = priority
        self.preferred = preferred
        self.exclude = exclude
        self.vendorMetadata = vendorMetadata
        self.json = [:]
    }

    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: AnyCodableValue].self)
        json = object
        selectorHint = object["selectorHint"]?.stringValue
        pinnedSelector = object["pinSelector"]?.stringValue ?? object["pinnedSelector"]?.stringValue
        aliases = object["aliases"]?.stringArray
        priority = object["priority"]?.numberValue
        preferred = object["preferred"]?.boolValue
        exclude = object["exclude"]?.boolValue
        vendorMetadata = (object["vendorMeta"] ?? object["vendorMetadata"])?.stringDictionary
    }

    /// The hints as a JSON object: verbatim when decoded, otherwise in
    /// @smallchat/core's spelling.
    public var jsonValue: [String: AnyCodableValue] {
        if !json.isEmpty { return json }
        var o: [String: AnyCodableValue] = [:]
        if let selectorHint { o["selectorHint"] = .string(selectorHint) }
        if let pinnedSelector { o["pinSelector"] = .string(pinnedSelector) }
        if let aliases { o["aliases"] = .array(aliases.map { .string($0) }) }
        if let priority { o["priority"] = .double(priority) }
        if let preferred { o["preferred"] = .bool(preferred) }
        if let exclude { o["exclude"] = .bool(exclude) }
        if let vendorMetadata { o["vendorMeta"] = .dict(vendorMetadata.mapValues { .string($0) }) }
        return o
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    public static func == (lhs: CompilerHint, rhs: CompilerHint) -> Bool {
        lhs.jsonValue == rhs.jsonValue
    }
}

/// Provider-level compiler hints.
///
/// Decoding accepts @smallchat/core's spellings too (`namespace`,
/// `selectorHint`) and keeps the hints object verbatim (`json`).
public struct ProviderCompilerHints: Sendable, Codable, Equatable {
    /// Default priority for all tools from this provider (ignored by dispatch).
    public let defaultPriority: Double?
    /// Namespace prefix for selectors (`namespace`): selectors become `<namespace>.<tool>`.
    public let namespacePrefix: String?
    /// Semantic context (`selectorHint`): appended to the embedding text of
    /// every tool of this provider that has no selectorHint of its own.
    public let semanticContext: String?
    /// The hints object as decoded (empty when built in code).
    public let json: [String: AnyCodableValue]

    public init(
        defaultPriority: Double? = nil,
        namespacePrefix: String? = nil,
        semanticContext: String? = nil
    ) {
        self.defaultPriority = defaultPriority
        self.namespacePrefix = namespacePrefix
        self.semanticContext = semanticContext
        self.json = [:]
    }

    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: AnyCodableValue].self)
        json = object
        defaultPriority = object["defaultPriority"]?.numberValue
        namespacePrefix = object["namespace"]?.stringValue ?? object["namespacePrefix"]?.stringValue
        semanticContext = object["selectorHint"]?.stringValue ?? object["semanticContext"]?.stringValue
    }

    /// The hints as a JSON object: verbatim when decoded, otherwise in
    /// @smallchat/core's spelling.
    public var jsonValue: [String: AnyCodableValue] {
        if !json.isEmpty { return json }
        var o: [String: AnyCodableValue] = [:]
        if let defaultPriority { o["defaultPriority"] = .double(defaultPriority) }
        if let namespacePrefix { o["namespace"] = .string(namespacePrefix) }
        if let semanticContext { o["selectorHint"] = .string(semanticContext) }
        return o
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    public static func == (lhs: ProviderCompilerHints, rhs: ProviderCompilerHints) -> Bool {
        lhs.jsonValue == rhs.jsonValue
    }
}

extension AnyCodableValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }

    var stringDictionary: [String: String]? {
        guard case .dict(let object) = self else { return nil }
        return object.compactMapValues(\.stringValue)
    }
}

// MARK: - Pre-compiled Vendor Package

/// SmallChatPackage -- the format of a pre-compiled vendor tool package.
///
/// This is what gets resolved from a dependency declaration.
/// Think of it as a compiled .framework -- the vendor has already done
/// the embedding and compilation, and the consumer just links it in.
public struct SmallChatPackage: Sendable, Codable {
    /// Package name (matches the dependency key).
    public let name: String
    /// Package version (semver).
    public let version: String
    /// Human-readable description.
    public let description: String?
    /// The vendor/author of this package.
    public let author: String?
    /// License identifier (SPDX).
    public let license: String?
    /// Pre-compiled provider manifests included in this package.
    public let providers: [PreCompiledProvider]
    /// Pre-computed embeddings for all tools, keyed by "providerId.toolName".
    public let embeddings: [String: [Float]]?
    /// Embedding model used to generate the pre-computed vectors.
    public let embeddingModel: String?
    /// Embedding dimensions.
    public let embeddingDimensions: Int?
    /// Package-level metadata.
    public let metadata: [String: String]?

    public init(
        name: String,
        version: String,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        providers: [PreCompiledProvider],
        embeddings: [String: [Float]]? = nil,
        embeddingModel: String? = nil,
        embeddingDimensions: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.providers = providers
        self.embeddings = embeddings
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.metadata = metadata
    }
}

/// PreCompiledProvider -- a provider manifest bundled inside a vendor package.
public struct PreCompiledProvider: Sendable, Codable {
    /// Provider ID.
    public let id: String
    /// Human-readable name.
    public let name: String
    /// Transport type.
    public let transportType: TransportType
    /// Endpoint (for remote transports).
    public let endpoint: String?
    /// Provider version.
    public let version: String?
    /// Provider-level compiler hints.
    public let compilerHints: ProviderCompilerHints?
    /// Tool definitions with vendor-supplied compiler hints.
    public let tools: [PreCompiledTool]

    public init(
        id: String,
        name: String,
        transportType: TransportType,
        endpoint: String? = nil,
        version: String? = nil,
        compilerHints: ProviderCompilerHints? = nil,
        tools: [PreCompiledTool]
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.endpoint = endpoint
        self.version = version
        self.compilerHints = compilerHints
        self.tools = tools
    }

    public struct PreCompiledTool: Sendable, Codable {
        public let name: String
        public let description: String
        public let inputSchema: [String: AnyCodableValue]
        public let compilerHints: CompilerHint?

        public init(
            name: String,
            description: String,
            inputSchema: [String: AnyCodableValue],
            compilerHints: CompilerHint? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.compilerHints = compilerHints
        }
    }
}
