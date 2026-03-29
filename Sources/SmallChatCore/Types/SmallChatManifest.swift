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
    /// Embedder type: "onnx" or "local".
    public let embedder: String?
    /// Deduplication threshold (0-1, default 0.95).
    public let deduplicationThreshold: Double?
    /// Collision warning threshold (0-1, default 0.89).
    public let collisionThreshold: Double?
    /// Enable semantic overload generation.
    public let generateSemanticOverloads: Bool?
    /// Semantic overload grouping threshold (0-1, default 0.82).
    public let semanticOverloadThreshold: Double?

    public init(
        embedder: String? = nil,
        deduplicationThreshold: Double? = nil,
        collisionThreshold: Double? = nil,
        generateSemanticOverloads: Bool? = nil,
        semanticOverloadThreshold: Double? = nil
    ) {
        self.embedder = embedder
        self.deduplicationThreshold = deduplicationThreshold
        self.collisionThreshold = collisionThreshold
        self.generateSemanticOverloads = generateSemanticOverloads
        self.semanticOverloadThreshold = semanticOverloadThreshold
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
public struct CompilerHint: Sendable, Codable {
    /// Selector hint override.
    public let selectorHint: String?
    /// Pinned canonical selector (bypasses embedding).
    public let pinnedSelector: String?
    /// Alternative names that resolve to this tool.
    public let aliases: [String]?
    /// Priority multiplier (>1.0 = boosted).
    public let priority: Double?
    /// Mark as preferred for its selector group.
    public let preferred: Bool?
    /// Exclude from compilation.
    public let exclude: Bool?
    /// Vendor-specific metadata.
    public let vendorMetadata: [String: String]?

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
    }
}

/// Provider-level compiler hints.
public struct ProviderCompilerHints: Sendable, Codable {
    /// Default priority for all tools from this provider.
    public let defaultPriority: Double?
    /// Namespace prefix for selectors.
    public let namespacePrefix: String?
    /// Semantic context hint for the provider.
    public let semanticContext: String?

    public init(
        defaultPriority: Double? = nil,
        namespacePrefix: String? = nil,
        semanticContext: String? = nil
    ) {
        self.defaultPriority = defaultPriority
        self.namespacePrefix = namespacePrefix
        self.semanticContext = semanticContext
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
