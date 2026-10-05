import Foundation
import SmallChatCore

// MARK: - RuntimeOptions

public struct RuntimeOptions: Sendable {
    public var selectorThreshold: Float
    public var cacheSize: Int
    /// Lowest score the resolution cache stores (default 0.85: HIGH and EXACT).
    public var minConfidence: Double
    public var modelVersion: String?
    public var selectorNamespace: SelectorNamespace?
    /// Opt-in semantic rate limiting of novel intents, per principal. Off when nil.
    public var rateLimiter: SemanticRateLimiterOptions?
    /// Tier thresholds and the dispatch policy's guards.
    public var dispatchConfig: DispatchConfig
    /// LLM client for verification (required below HIGH by default),
    /// decomposition and refinement questions.
    public var llmClient: any LLMClient
    /// Jev judge for below-HIGH or ambiguous shortlists. Nil leaves dispatch unchanged.
    public var jev: JevJudge?
    /// Intent pins (see `IntentPinRegistry`).
    public var intentPins: [IntentPin]
    /// contentHash of the artifact the tools came from, recorded in every proof.
    public var artifactHash: String?

    public init(
        selectorThreshold: Float = 0.95,
        cacheSize: Int = 1024,
        minConfidence: Double = 0.85,
        modelVersion: String? = nil,
        selectorNamespace: SelectorNamespace? = nil,
        rateLimiter: SemanticRateLimiterOptions? = nil,
        dispatchConfig: DispatchConfig = DispatchConfig(),
        llmClient: any LLMClient = NoOpLLMClient(),
        jev: JevJudge? = nil,
        intentPins: [IntentPin] = [],
        artifactHash: String? = nil
    ) {
        self.selectorThreshold = selectorThreshold
        self.cacheSize = cacheSize
        self.minConfidence = minConfidence
        self.modelVersion = modelVersion
        self.selectorNamespace = selectorNamespace
        self.rateLimiter = rateLimiter
        self.dispatchConfig = dispatchConfig
        self.llmClient = llmClient
        self.jev = jev
        self.intentPins = intentPins
        self.artifactHash = artifactHash
    }
}

// MARK: - ToolRuntime

/// ToolRuntime -- the top-level runtime that manages everything.
///
/// Owns the selector table, dispatch context, tool classes, and provides
/// the main dispatch entry point. Also supports method swizzling for
/// contextual tool replacement.
public actor ToolRuntime {
    public let selectorTable: SelectorTable
    public let cache: ResolutionCache
    public let context: DispatchContext
    public let selectorNamespace: SelectorNamespace

    private let vectorIndex: any VectorIndex
    private let embedder: any Embedder

    public init(
        vectorIndex: any VectorIndex,
        embedder: any Embedder,
        options: RuntimeOptions = RuntimeOptions()
    ) {
        self.vectorIndex = vectorIndex
        self.embedder = embedder

        let versionContext = CacheVersionContext(
            providerVersions: [:],
            modelVersion: options.modelVersion ?? "",
            schemaFingerprints: [:]
        )

        let cache = ResolutionCache(
            maxSize: options.cacheSize,
            minConfidence: options.minConfidence,
            versionContext: versionContext
        )
        self.cache = cache

        let selectorTable = SelectorTable(
            index: vectorIndex,
            embedder: embedder,
            threshold: options.selectorThreshold
        )
        self.selectorTable = selectorTable

        let selectorNamespace = options.selectorNamespace ?? SelectorNamespace()
        self.selectorNamespace = selectorNamespace

        let pins = IntentPinRegistry()
        for pin in options.intentPins { pins.pin(pin) }

        self.context = DispatchContext(
            selectorTable: selectorTable,
            cache: cache,
            vectorIndex: vectorIndex,
            embedder: embedder,
            selectorNamespace: selectorNamespace,
            intentPins: pins,
            dispatchConfig: options.dispatchConfig,
            llmClient: options.llmClient,
            jev: options.jev,
            rateLimiter: options.rateLimiter.map { SemanticRateLimiter(options: $0) },
            artifactHash: options.artifactHash
        )
    }

    // MARK: - Class Registration

    /// Register a tool class (provider).
    ///
    /// Throws SelectorShadowingError if the class contains selectors that
    /// would shadow protected core selectors.
    public func registerClass(_ toolClass: ToolClass) async throws {
        try await context.registerClass(toolClass)
    }

    /// Remove a provider by name. Returns false when none has that name.
    @discardableResult
    public func unregisterClass(_ name: String) async -> Bool {
        await context.unregisterClass(name)
    }

    /// Register a tool class as a core system provider.
    ///
    /// All of its current selectors are marked as core (protected by default).
    /// Future ToolClasses cannot shadow these selectors unless they are
    /// explicitly marked as swizzlable.
    public func registerCoreClass(_ toolClass: ToolClass, swizzlable: Bool = false) async throws {
        try await context.registerClass(toolClass)

        let selectors = Array(toolClass.dispatchTable.keys).map { canonical in
            (canonical: canonical, swizzlable: swizzlable)
        }
        selectorNamespace.registerCoreSelectors(toolClass.name, selectors: selectors)
    }

    /// Register a protocol
    public func registerProtocol(_ proto: ToolProtocolDef) async {
        await context.registerProtocol(proto)
    }

    /// Load a category -- bolts methods onto all providers conforming
    /// to the specified protocol.
    ///
    /// Like +load on an Obj-C category: the runtime adds the new methods
    /// to all conforming classes and flushes the cache.
    public func loadCategory(_ category: ToolCategory) async throws {
        let categorySelectors = category.methods.map { $0.selector.canonical }

        for toolClass in await context.getClasses() {
            let conforming = toolClass.protocols.contains { $0.name == category.extendsProtocol }
            guard conforming else { continue }

            // Only check shadowing for selectors being added to this class
            try selectorNamespace.assertNoShadowing(toolClass.name, categorySelectors)

            for method in category.methods {
                toolClass.addMethod(method.selector, imp: method.imp)
            }
        }

        // Re-index and flush -- new methods may shadow cached resolutions
        await context.reindex()
        await cache.flush()
    }

    /// Register an overloaded method on a tool class.
    public func addOverload(
        _ toolClass: ToolClass,
        selector: ToolSelector,
        signature: SCMethodSignature,
        imp: any ToolIMP,
        originalToolName: String? = nil,
        isSemanticOverload: Bool = false
    ) async throws {
        // Guard: check that the overload doesn't shadow a protected core selector
        try selectorNamespace.assertNoShadowing(toolClass.name, [selector.canonical])

        try toolClass.addOverload(
            selector,
            signature: signature,
            imp: imp,
            originalToolName: originalToolName,
            isSemanticOverload: isSemanticOverload
        )
        // Re-index and flush -- overloads change resolution behavior
        await context.reindex()
        await cache.flush()
    }

    /// Swizzle: replace the IMP for a selector in a specific provider.
    /// Returns the original IMP.
    ///
    /// Use cases: testing/mocking, environment-specific routing,
    /// capability upgrades mid-session.
    public func swizzle(
        _ toolClass: ToolClass,
        selector: ToolSelector,
        newImp: any ToolIMP
    ) async throws -> (any ToolIMP)? {
        // Guard: core selectors can only be swizzled if marked swizzlable.
        try selectorNamespace.assertNoShadowing(toolClass.name, [selector.canonical])

        let original = toolClass.swizzleMethod(selector, newImp: newImp)

        // Re-index (tool ids change) and flush every cached resolution:
        // they are keyed by intent, not by selector.
        await context.reindex()
        await cache.flush()

        return original
    }

    // MARK: - Dispatch

    /// Fluent dispatch -- returns a DispatchBuilder for chaining .withArgs().exec()/.stream().
    ///
    /// Usage:
    ///   let result = try await runtime.dispatch("fetch url").withArgs(["url": "https://example.com"]).exec()
    public func dispatch(_ intent: String) -> DispatchBuilder<[String: any Sendable]> {
        DispatchBuilder(context: context, intent: intent)
    }

    /// Resolve an intent to at most one tool (`Resolution`). Never executes.
    /// Run the proposal with `dispatchById(_:args:options:)`, passing
    /// `resolution.proof.proofDigest` as `resolutionDigest` to link the two.
    public func resolve(_ intent: String, options: ResolveOptions = ResolveOptions()) async throws -> Resolution {
        try await context.resolve(intent, options: options)
    }

    /// Execute exactly the tool `toolId` (`<providerId>/<toolName>`): O(1),
    /// no embedding. Arguments are validated against its inputSchema first.
    public func dispatchById(
        _ toolId: String,
        args: [String: any Sendable] = [:],
        options: DispatchByIdOptions = DispatchByIdOptions()
    ) async throws -> ToolResult {
        try await context.dispatchById(toolId, args: args, options: options)
    }

    /// Resolve an intent and execute exactly the chosen tool under the
    /// dispatch policy. When resolution does not settle on one tool, nothing
    /// runs: the result is `isError` with `metadata["outcome"]`
    /// (`DispatchOutcomeCode`) and the candidates.
    public func dispatch(_ intent: String, args: [String: any Sendable], options: DispatchOptions = DispatchOptions()) async throws -> ToolResult {
        try await context.dispatch(intent, args: args, options: options)
    }

    /// Fluent dispatch builder -- chainable API for constructing dispatches.
    ///
    /// Usage:
    ///   let result = try await runtime.intent("search documents")
    ///     .withArgs(["query": "hello", "limit": 10])
    ///     .exec()
    public func intent<TArgs: Sendable>(_ intentStr: String) -> DispatchBuilder<TArgs> {
        DispatchBuilder<TArgs>(context: context, intent: intentStr)
    }

    // MARK: - Version Management

    /// Set a provider's version. Cached entries for this provider auto-expire
    /// on next lookup if the version has changed.
    public func setProviderVersion(_ providerId: String, _ version: String) async {
        await cache.setProviderVersion(providerId, version)
    }

    /// Set the model/embedder version. All cached entries become stale
    /// if they were tagged with a different model version.
    public func setModelVersion(_ version: String) async {
        await cache.setModelVersion(version)
    }

    /// Recompute and update a provider's schema fingerprint.
    /// Call this after a provider hot-reloads or changes its tool schemas.
    /// Stale cache entries auto-expire on next lookup.
    public func updateSchemaFingerprint(_ toolClass: ToolClass) async {
        var schemas: [(name: String, inputSchema: JSONSchemaType)] = []
        for (_, imp) in toolClass.dispatchTable {
            if let schema = imp.schema {
                schemas.append((name: schema.name, inputSchema: schema.inputSchema))
            }
        }
        let fingerprint = computeSchemaFingerprint(schemas)
        await cache.setSchemaFingerprint(toolClass.name, fingerprint)
    }

    /// Register a hook that fires on cache invalidation events.
    /// Returns an ID for bookkeeping.
    ///
    /// Use for hot-reload coordination: downstream consumers (UI, LLM context)
    /// react to invalidation without polling.
    @discardableResult
    public func invalidateOn(_ hook: @escaping InvalidationHook) async -> Int {
        await cache.invalidateOn(hook)
    }

    // MARK: - Streaming

    /// Streaming dispatch -- yields DispatchEvent objects for real-time UI feedback.
    ///
    /// Events flow: resolving -> tool-start -> chunk* -> done (or error at any point).
    /// When the resolved IMP supports progressive inference, the flow becomes:
    ///   resolving -> tool-start -> inference-delta* -> chunk -> done
    public func dispatchStream(
        _ intent: String,
        args: [String: any Sendable]? = nil
    ) -> AsyncThrowingStream<DispatchEvent, Error> {
        smallchatDispatchStream(context: context, intent: intent, args: args)
    }

    /// Streaming dispatch of exactly the tool `toolId`.
    public func dispatchStreamById(
        _ toolId: String,
        args: [String: any Sendable] = [:]
    ) -> AsyncThrowingStream<DispatchEvent, Error> {
        smallchatDispatchStreamById(context: context, toolId: toolId, args: args)
    }

    /// Progressive inference stream -- convenience that yields only the token
    /// text from inference deltas, filtering out dispatch lifecycle events.
    ///
    /// Falls back gracefully: if the resolved IMP doesn't support
    /// executeInference, the final assembled chunk content is yielded as
    /// a single string.
    public func inferenceStream(
        _ intent: String,
        args: [String: any Sendable]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let eventStream = dispatchStream(intent, args: args)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var sawDelta = false
                do {
                    for try await event in eventStream {
                        switch event {
                        case .inferenceDelta(let delta, _):
                            sawDelta = true
                            continuation.yield(delta.text)

                        case .chunk(let content, _) where !sawDelta:
                            switch content {
                            case .string(let text):
                                continuation.yield(text)
                            default:
                                if let data = try? JSONEncoder().encode(content),
                                   let text = String(data: data, encoding: .utf8) {
                                    continuation.yield(text)
                                }
                            }

                        case .error(let message, _):
                            continuation.finish(throwing: DispatchStreamError(message: message))
                            return

                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Header Generation

    /// Generate the LLM-readable "header file" -- a minimal capability summary.
    public func generateHeader() async -> String {
        let classes = await context.getClasses()
        var lines: [String] = ["Available capabilities:"]

        // Group by protocol
        var protocolProviders: [String: [String]] = [:]
        for cls in classes {
            for proto in cls.protocols {
                protocolProviders[proto.name, default: []].append(cls.name)
            }
        }

        for (protocolName, providers) in protocolProviders {
            lines.append("- \(protocolName): \(providers.joined(separator: ", "))")
        }

        // List standalone providers without protocols
        for cls in classes {
            if cls.protocols.isEmpty {
                let selectors = cls.allSelectors()
                let overloadCount = cls.overloadTables.count
                let overloadSuffix = overloadCount > 0
                    ? " (\(overloadCount) overloaded)"
                    : ""
                lines.append("- \(cls.name): \(selectors.count) tools\(overloadSuffix)")
            }
        }

        // List overloaded selectors
        var hasOverloads = false
        for cls in classes {
            for (canonical, table) in cls.overloadTables {
                if !hasOverloads {
                    lines.append("")
                    lines.append("Overloaded methods:")
                    hasOverloads = true
                }
                let overloads = table.allOverloads()
                let signatures = overloads
                    .map { $0.signature.signatureKey }
                    .joined(separator: ", ")
                lines.append("  \(canonical): \(overloads.count) overloads [\(signatures)]")
            }
        }

        lines.append("")
        lines.append("To use a tool, call it by id (<provider>/<tool>), or describe what you want")
        lines.append("to do: the runtime proposes a tool, and runs it only when the dispatch")
        lines.append("policy allows (HIGH or EXACT confidence, or an LLM verifier's approval).")
        lines.append("Overloaded tools accept different argument types and counts.")

        return lines.joined(separator: "\n")
    }
}
