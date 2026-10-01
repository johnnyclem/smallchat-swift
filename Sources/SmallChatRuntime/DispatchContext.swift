import Foundation
import SmallChatCore

// MARK: - RegisteredTool

/// One executable tool in the dispatch index.
public struct RegisteredTool: Sendable {
    /// Canonical tool id `<providerId>/<toolName>`
    public let id: String
    public let imp: any ToolIMP
    /// Selector canonicals that dispatch to this tool
    public internal(set) var selectors: [String]
}

// MARK: - DispatchContext

/// DispatchContext -- the runtime context for tool dispatch.
///
/// Holds the selector table, resolution cache, tool classes (providers),
/// vector index, protocol registry, intent pins and the dispatch policy
/// configuration, plus the dispatch index (selector -> classes, tool id ->
/// tool). `resolve(_:)` chooses a tool and never executes;
/// `dispatchById(_:args:)` runs exactly the named tool; `dispatch` is
/// resolve-then-run under the same policy.
public actor DispatchContext {
    public let selectorTable: SelectorTable
    public let cache: ResolutionCache
    public let vectorIndex: any VectorIndex
    public let embedder: any Embedder
    public let selectorNamespace: SelectorNamespace
    public let intentPins: IntentPinRegistry
    public let dispatchConfig: DispatchConfig
    /// LLM client for verification, decomposition and refinement questions.
    public let llmClient: any LLMClient
    /// Opt-in semantic rate limiter (nil unless `RuntimeOptions.rateLimiter` is set).
    public let rateLimiter: SemanticRateLimiter?
    /// contentHash of the artifact the tools came from, recorded in every proof.
    public let artifactHash: String?
    /// Records accepted and refined dispatches, when set.
    public let observer: DispatchObserver?

    private var toolClasses: [String: ToolClass] = [:]
    /// Class names in registration order (resolution walks classes in it).
    private var classOrder: [String] = []
    private var protocols: [String: ToolProtocolDef] = [:]
    /// Selector canonical -> the classes that declare it (directly or through a superclass).
    private var selectorToClasses: [String: [ToolClass]] = [:]
    /// Canonical tool id -> the one IMP it names (O(1) dispatch by id).
    private var toolsById: [String: RegisteredTool] = [:]
    /// Ids claimed by two different IMPs; dispatch by such an id is refused.
    private var ambiguousIds: Set<String> = []

    public init(
        selectorTable: SelectorTable,
        cache: ResolutionCache,
        vectorIndex: any VectorIndex,
        embedder: any Embedder,
        selectorNamespace: SelectorNamespace? = nil,
        intentPins: IntentPinRegistry? = nil,
        dispatchConfig: DispatchConfig = DispatchConfig(),
        llmClient: any LLMClient = NoOpLLMClient(),
        rateLimiter: SemanticRateLimiter? = nil,
        artifactHash: String? = nil,
        observer: DispatchObserver? = nil
    ) {
        self.selectorTable = selectorTable
        self.cache = cache
        self.vectorIndex = vectorIndex
        self.embedder = embedder
        self.selectorNamespace = selectorNamespace ?? SelectorNamespace()
        self.intentPins = intentPins ?? IntentPinRegistry()
        self.dispatchConfig = dispatchConfig
        self.llmClient = llmClient
        self.rateLimiter = rateLimiter
        self.artifactHash = artifactHash
        self.observer = observer
    }

    /// The policy options every dispatch path evaluates against.
    public var policyOptions: DispatchPolicyOptions {
        DispatchPolicyOptions(
            thresholds: dispatchConfig.thresholds,
            requireLLMForSubHighDispatch: dispatchConfig.requireLLMForSubHighDispatch,
            treatUnannotatedAsDestructive: dispatchConfig.treatUnannotatedAsDestructive
        )
    }

    // MARK: - Registration

    /// Register a provider (ToolClass). A class with the same name replaces
    /// the one registered before: its selectors and tool ids are re-indexed
    /// from scratch, so nothing of the old class stays reachable. Cached
    /// resolutions are flushed either way.
    ///
    /// Throws SelectorShadowingError if the class contains selectors that
    /// would shadow protected core selectors.
    public func registerClass(_ toolClass: ToolClass) async throws {
        let ownSelectors = Array(toolClass.dispatchTable.keys)
        try selectorNamespace.assertNoShadowing(toolClass.name, ownSelectors)

        let replaces = toolClasses[toolClass.name] != nil
        toolClasses[toolClass.name] = toolClass
        if replaces {
            reindex()
        } else {
            classOrder.append(toolClass.name)
            indexClass(toolClass)
        }
        await cache.flush()
    }

    /// Remove a provider by name: its tools leave the dispatch index and the
    /// cache is flushed. Returns false when no class has that name.
    @discardableResult
    public func unregisterClass(_ name: String) async -> Bool {
        guard toolClasses.removeValue(forKey: name) != nil else { return false }
        classOrder.removeAll { $0 == name }
        reindex()
        await cache.flush()
        return true
    }

    /// Rebuild the dispatch index from scratch. Call after a registry
    /// mutation that changes existing classes (categories, overloads,
    /// swizzling); `ToolRuntime` does.
    public func reindex() {
        selectorToClasses.removeAll()
        toolsById.removeAll()
        ambiguousIds.removeAll()
        for name in classOrder {
            if let toolClass = toolClasses[name] { indexClass(toolClass) }
        }
    }

    private func indexClass(_ toolClass: ToolClass) {
        for canonical in Set(toolClass.allSelectors()).sorted() {
            var owners = selectorToClasses[canonical] ?? []
            if !owners.contains(where: { $0 === toolClass }) { owners.append(toolClass) }
            selectorToClasses[canonical] = owners
            if let imp = toolClass.resolveSelector(Self.probe(canonical)) {
                indexTool(imp, selector: canonical)
            }
        }
        for (canonical, table) in toolClass.overloadTables.sorted(by: { $0.key < $1.key }) {
            for entry in table.allOverloads() { indexTool(entry.imp, selector: canonical) }
        }
    }

    private func indexTool(_ imp: any ToolIMP, selector: String) {
        let id = imp.toolId
        if var existing = toolsById[id] {
            if existing.imp === imp {
                if !existing.selectors.contains(selector) {
                    existing.selectors.append(selector)
                    toolsById[id] = existing
                }
            } else {
                ambiguousIds.insert(id)
            }
        } else {
            toolsById[id] = RegisteredTool(id: id, imp: imp, selectors: [selector])
        }
    }

    /// A selector value to look a canonical up in a class's dispatch table.
    static func probe(_ canonical: String) -> ToolSelector {
        ToolSelector(vector: [], canonical: canonical, parts: [], arity: 0)
    }

    // MARK: - Lookup

    /// The classes that declare a selector canonical -- the resolution candidates.
    public func classesForSelector(_ canonical: String) -> [ToolClass] {
        selectorToClasses[canonical] ?? []
    }

    /// The tool a canonical id names, or nil when no tool has that id (or two
    /// different tools claim it). O(1); no embedding.
    public func getTool(_ toolId: String) -> RegisteredTool? {
        ambiguousIds.contains(toolId) ? nil : toolsById[toolId]
    }

    /// Whether two different tools claim this id (dispatch by it is refused).
    public func isAmbiguousToolId(_ toolId: String) -> Bool {
        ambiguousIds.contains(toolId)
    }

    /// Every registered tool id, sorted.
    public func toolIds() -> [String] {
        toolsById.keys.filter { !ambiguousIds.contains($0) }.sorted()
    }

    /// The tool a selector canonical dispatches to (its first owning class).
    public func toolForSelector(_ canonical: String) async -> (imp: any ToolIMP, selector: ToolSelector, toolId: String)? {
        guard let selector = await selectorTable.get(canonical) else { return nil }
        for toolClass in classesForSelector(canonical) {
            if let imp = toolClass.resolveSelector(selector) { return (imp, selector, imp.toolId) }
        }
        return nil
    }

    /// Register a protocol
    public func registerProtocol(_ proto: ToolProtocolDef) {
        protocols[proto.name] = proto
    }

    /// ISA chain -- check protocol conformance for a selector
    public func resolveViaProtocol(_ selector: ToolSelector) -> ToolCandidate? {
        for name in classOrder {
            guard let toolClass = toolClasses[name] else { continue }
            for proto in toolClass.protocols {
                let isRequired = proto.requiredSelectors.contains { $0.canonical == selector.canonical }
                let isOptional = proto.optionalSelectors.contains { $0.canonical == selector.canonical }
                if isRequired || isOptional, let imp = toolClass.resolveSelector(selector) {
                    return ToolCandidate(imp: imp, confidence: 0.8, selector: selector)
                }
            }
        }
        return nil
    }

    /// All registered tool classes, in registration order.
    public func getClasses() -> [ToolClass] {
        classOrder.compactMap { toolClasses[$0] }
    }

    // MARK: - Pins

    /// The pinned canonicals that apply to a tool: every pinned selector the
    /// tool is reachable through -- its own selectors, the overload tables it
    /// is a variant in, and `via`, the selector a candidate matched through.
    func pinnedCanonicals(of toolId: String, via: String?) -> [String] {
        guard intentPins.size > 0 else { return [] }
        var reachable = Set(toolsById[toolId]?.selectors ?? [])
        if let via { reachable.insert(via) }
        return intentPins.pinnedCanonicals().filter { reachable.contains($0) }
    }

    /// Whether any intent pin applies to this tool.
    public func isPinnedTool(_ toolId: String, via: String? = nil) -> Bool {
        !pinnedCanonicals(of: toolId, via: via).isEmpty
    }

    /// How the intent pins apply to one tool for one intent. `ownSimilarity`
    /// computes the cosine similarity between the intent's own embedding and
    /// a selector (for `elevated` pins).
    func pinStates(
        for toolId: String,
        intent: String,
        via: String?,
        ownSimilarity: (ToolSelector) async throws -> Double
    ) async throws -> [PinState] {
        var states: [PinState] = []
        for canonical in pinnedCanonicals(of: toolId, via: via) {
            guard let pin = intentPins.getPin(canonical) else { continue }
            let phrase = intentPins.matchesPinnedPhrase(canonical, intent: intent)
            if pin.policy == .exact {
                states.append(PinState(canonical: canonical, policy: .exact, satisfied: phrase))
                continue
            }
            var similarity: Double?
            if !phrase, let pinned = await selectorTable.get(canonical) {
                similarity = try await ownSimilarity(pinned)
            }
            let verdict = intentPins.checkSimilarity(candidateCanonical: canonical, similarity: similarity ?? 0, intent: intent)
            states.append(PinState(
                canonical: canonical,
                policy: .elevated,
                satisfied: phrase || verdict?.verdict == .accept,
                similarity: similarity,
                requiredThreshold: verdict?.requiredThreshold
            ))
        }
        return states
    }

    // MARK: - Proofs

    /// A new proof stamped with this context's thresholds, guards and identity.
    public func newProof(intent: String?) -> ResolutionProof {
        ResolutionProof(
            intent: intent,
            thresholds: dispatchConfig.thresholds,
            guards: ProofGuards(
                requireLLMForSubHighDispatch: dispatchConfig.requireLLMForSubHighDispatch,
                strict: dispatchConfig.strict,
                llmVerifier: llmClient.providesVerification,
                treatUnannotatedAsDestructive: dispatchConfig.treatUnannotatedAsDestructive
            ),
            embedder: embedder.fingerprint,
            artifactHash: artifactHash
        )
    }
}
