import Foundation

// MARK: - Resolution outcome and decision codes (@smallchat/core 1.0)

/// What resolution concluded.
public enum ResolutionOutcome: String, Sendable, Codable, Equatable {
    /// Exactly one tool is chosen and may execute.
    case resolved
    /// There are candidates, but the policy or verification refuses to pick
    /// one on its own; the caller chooses (by tool id).
    case needsDisambiguation = "needs-disambiguation"
    /// Nothing plausible matched.
    case unresolved
    /// The opt-in semantic rate limiter refused to embed the intent for
    /// this principal; retry after the window drains.
    case throttled
}

/// Where a candidate came from.
public enum CandidateSource: String, Sendable, Codable, Equatable {
    case exactId = "exact-id"
    case pin
    case semanticMapExact = "semantic-map-exact"
    case semanticMapSimilar = "semantic-map-similar"
    case cache
    case vector
    case overload
    case `protocol`
}

/// The rule that settled an outcome.
public enum DecisionCode: String, Sendable, Codable, Equatable {
    /// Addressed by canonical tool id (dispatchById)
    case exactId = "exact-id"
    /// The intent is a pinned phrase (pin canonical or alias)
    case pinExact = "pin-exact"
    /// This exact intent was taught through a resolved refinement
    case learnedExact = "learned-exact"
    /// A cached resolution of this intent
    case cache
    /// Top-ranked candidate at EXACT/HIGH tier
    case ranked
    /// Sub-HIGH candidate approved by the LLM verifier
    case llmVerified = "llm-verified"
    /// Sub-HIGH candidate passed schema/keyword verification (requireLLMForSubHighDispatch off)
    case verified
    /// LOW-tier or unmatched intent split into sub-intents, each dispatched separately
    case decomposed
    /// Sub-HIGH candidate without LLM approval
    case needsLLMVerifier = "needs-llm-verifier"
    /// Every candidate failed verification
    case verificationFailed = "verification-failed"
    /// Destructive tool below EXACT tier
    case destructiveNeedsExact = "destructive-needs-exact"
    /// Tool pinned 'exact' and the intent is not one of its pinned phrases
    case pinExactRequired = "pin-exact-required"
    /// Tool pinned 'elevated' and the intent's own similarity is below the pin threshold
    case pinElevatedRequired = "pin-elevated-required"
    /// Best candidate is below the LOW threshold
    case belowThreshold = "below-threshold"
    /// Nothing scored above the search floor
    case noCandidates = "no-candidates"
    /// dispatchById with an id that is not registered (or is ambiguous)
    case unknownTool = "unknown-tool"
    /// The semantic rate limiter refused to embed the intent for this principal
    case rateLimited = "rate-limited"
}

/// The stage of resolution or execution a proof step records.
public enum ProofStage: String, Sendable, Codable, Equatable {
    case exactId = "exact_id"
    case intentPin = "intent_pin"
    case semanticMap = "semantic_map"
    case cache
    case vectorSearch = "vector_search"
    case overload
    case `protocol`
    case verification
    case policy
    case decomposition
    case refinement
    case rateLimit = "rate_limit"
    case validation
    case execution
    case validateIntent = "validate_intent"
}

// MARK: - Proof

/// One row of a proof's candidate table.
public struct ProofCandidate: Sendable, Codable, Equatable {
    /// Canonical tool id `<providerId>/<toolName>`
    public var toolId: String
    /// Selector canonical the candidate matched through
    public var selector: String
    /// Score the decision used (quantized)
    public var score: Double
    /// Cosine similarity of this intent's own embedding to the selector, or
    /// nil when the candidate did not come from a vector comparison
    public var similarity: Double?
    public var tier: DispatchTier
    public var source: CandidateSource
    /// The rule that excluded the candidate (nil: eligible)
    public var excluded: String?

    public init(
        toolId: String,
        selector: String,
        score: Double,
        similarity: Double?,
        tier: DispatchTier,
        source: CandidateSource,
        excluded: String? = nil
    ) {
        self.toolId = toolId
        self.selector = selector
        self.score = score
        self.similarity = similarity
        self.tier = tier
        self.source = source
        self.excluded = excluded
    }

    public var jsonValue: AnyCodableValue {
        var object: [String: AnyCodableValue] = [
            "toolId": .string(toolId),
            "selector": .string(selector),
            "score": .double(score),
            "similarity": similarity.map { .double($0) } ?? .null,
            "tier": .string(tier.rawValue),
            "source": .string(source.rawValue),
        ]
        if let excluded { object["excluded"] = .string(excluded) }
        return .dict(object)
    }
}

/// One step of a proof.
public struct ProofStep: Sendable, Codable, Equatable {
    public var stage: ProofStage
    /// What happened at this stage, for humans
    public var decision: String
    /// The facts behind it (never raw arguments)
    public var detail: [String: AnyCodableValue]?

    public init(stage: ProofStage, decision: String, detail: [String: AnyCodableValue]? = nil) {
        self.stage = stage
        self.decision = decision
        self.detail = detail
    }

    public var jsonValue: AnyCodableValue {
        var object: [String: AnyCodableValue] = ["stage": .string(stage.rawValue), "decision": .string(decision)]
        if let detail { object["detail"] = .dict(detail) }
        return .dict(object)
    }
}

/// Guards in force when a decision was made.
public struct ProofGuards: Sendable, Codable, Equatable {
    public var requireLLMForSubHighDispatch: Bool
    public var strict: Bool
    /// Whether an LLM verifier was configured
    public var llmVerifier: Bool
    public var treatUnannotatedAsDestructive: Bool

    public init(requireLLMForSubHighDispatch: Bool = true, strict: Bool = false, llmVerifier: Bool = false, treatUnannotatedAsDestructive: Bool = false) {
        self.requireLLMForSubHighDispatch = requireLLMForSubHighDispatch
        self.strict = strict
        self.llmVerifier = llmVerifier
        self.treatUnannotatedAsDestructive = treatUnannotatedAsDestructive
    }
}

/// Wall-clock timings of a proof (excluded from `proofDigest`).
public struct ProofTimings: Sendable, Codable, Equatable {
    public var totalMs: Double
    public var stepsMs: [Double]

    public init(totalMs: Double = 0, stepsMs: [Double] = []) {
        self.totalMs = totalMs
        self.stepsMs = stepsMs
    }
}

/// A structured, replayable record of why a tool was (or was not) chosen,
/// and which tool actually ran (the shape of @smallchat/core 1.0's
/// `ResolutionProof`, version 1).
///
/// Everything that determines a decision is recorded: the candidate table
/// with scores and tiers, the thresholds and guards in force, the embedder
/// fingerprint and artifact hash, the decision code, and the canonical
/// call digest of what executed. Raw arguments are never recorded.
///
/// `proofDigest` is `sha256hex(UTF8("smallchat.proof.v1") || 0x00 ||
/// UTF8(JCS(proof without "timings" and "proofDigest"))`, so two runs that
/// made the same decision from the same inputs have the same digest
/// whatever their timings. The step texts are this implementation's, so a
/// Swift and a TypeScript proof of the same decision have the same shape,
/// outcome, decision, candidates and call digest, but not the same
/// `proofDigest`.
public struct ResolutionProof: Sendable, Codable, Equatable {
    public var version: Int = 1
    /// The intent resolved, or nil for a dispatch by tool id
    public var intent: String?
    public var outcome: ResolutionOutcome = .unresolved
    public var decision: DecisionCode = .noCandidates
    public var tier: DispatchTier = .none
    /// Tool id resolution chose, or nil
    public var chosen: String?
    /// Score of the chosen candidate, or nil
    public var confidence: Double?
    /// Tool id that actually executed, or nil when nothing ran
    public var ran: String?
    /// Canonical call digest of the executed call, or nil
    public var callDigest: String?
    /// Proof digest of the resolution a dispatch by id acted on, when linked
    public var resolutionDigest: String?
    /// Every candidate considered, best first; excluded ones last
    public var candidates: [ProofCandidate] = []
    public var thresholds: TierThresholds = .default
    public var guards: ProofGuards = ProofGuards()
    /// Fingerprint of the embedder intents were embedded with
    public var embedder: EmbedderFingerprint?
    /// contentHash of the artifact the runtime was loaded from, when known
    public var artifactHash: String?
    public var steps: [ProofStep] = []
    /// Excluded from `proofDigest`
    public var timings: ProofTimings = ProofTimings()
    /// Digest of everything above except timings (see the type's documentation)
    public var proofDigest: String = ""

    public init(
        intent: String? = nil,
        thresholds: TierThresholds = .default,
        guards: ProofGuards = ProofGuards(),
        embedder: EmbedderFingerprint? = nil,
        artifactHash: String? = nil
    ) {
        self.intent = intent
        self.thresholds = thresholds
        self.guards = guards
        self.embedder = embedder
        self.artifactHash = artifactHash
    }

    /// The tier of the chosen (or best) candidate.
    @available(*, deprecated, renamed: "tier")
    public var finalTier: DispatchTier { tier }

    /// Append a step; its elapsed time goes to `timings`, outside the digest.
    public mutating func addStep(_ step: ProofStep, elapsedMs: Double = 0) {
        steps.append(step)
        timings.stepsMs.append(elapsedMs)
        timings.totalMs += elapsedMs
    }

    /// Append a step.
    public mutating func addStep(_ stage: ProofStage, _ decision: String, detail: [String: AnyCodableValue]? = nil, elapsedMs: Double = 0) {
        addStep(ProofStep(stage: stage, decision: decision, detail: detail), elapsedMs: elapsedMs)
    }

    /// The decision content (everything but `timings` and `proofDigest`) as JSON.
    public var bodyJSON: [String: AnyCodableValue] {
        func optional(_ s: String?) -> AnyCodableValue { s.map { .string($0) } ?? .null }
        return [
            "version": .int(version),
            "intent": optional(intent),
            "outcome": .string(outcome.rawValue),
            "decision": .string(decision.rawValue),
            "tier": .string(tier.rawValue),
            "chosen": optional(chosen),
            "confidence": confidence.map { .double($0) } ?? .null,
            "ran": optional(ran),
            "callDigest": optional(callDigest),
            "resolutionDigest": optional(resolutionDigest),
            "candidates": .array(candidates.map(\.jsonValue)),
            "thresholds": .dict([
                "exact": .double(thresholds.exact),
                "high": .double(thresholds.high),
                "medium": .double(thresholds.medium),
                "low": .double(thresholds.low),
            ]),
            "guards": .dict([
                "requireLLMForSubHighDispatch": .bool(guards.requireLLMForSubHighDispatch),
                "strict": .bool(guards.strict),
                "llmVerifier": .bool(guards.llmVerifier),
                "treatUnannotatedAsDestructive": .bool(guards.treatUnannotatedAsDestructive),
            ]),
            "embedder": embedder.map { .dict($0.jsonValue) } ?? .null,
            "artifactHash": optional(artifactHash),
            "steps": .array(steps.map(\.jsonValue)),
        ]
    }

    /// The whole proof as JSON.
    public var jsonValue: AnyCodableValue {
        var object = bodyJSON
        object["timings"] = .dict([
            "totalMs": .double(timings.totalMs),
            "stepsMs": .array(timings.stepsMs.map { .double($0) }),
        ])
        object["proofDigest"] = .string(proofDigest)
        return .dict(object)
    }

    /// Domain-separation prefix of the proof digest.
    public static let digestDomain = "smallchat.proof.v1"

    /// The digest of the decision content (see the type's documentation).
    public func computeDigest() -> String {
        // The body holds only finite numbers and strings from runtime state;
        // canonicalization cannot fail on it.
        (try? domainDigest(Self.digestDomain, canonicalJSON(.dict(bodyJSON)))) ?? ""
    }

    /// Recompute and store `proofDigest`. Call after the last change.
    public mutating func finalize() {
        proofDigest = computeDigest()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    private enum CodingKeys: String, CodingKey {
        case version, intent, outcome, decision, tier, chosen, confidence, ran, callDigest, resolutionDigest
        case candidates, thresholds, guards, embedder, artifactHash, steps, timings, proofDigest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        outcome = try c.decodeIfPresent(ResolutionOutcome.self, forKey: .outcome) ?? .unresolved
        decision = try c.decodeIfPresent(DecisionCode.self, forKey: .decision) ?? .noCandidates
        tier = try c.decodeIfPresent(DispatchTier.self, forKey: .tier) ?? .none
        chosen = try c.decodeIfPresent(String.self, forKey: .chosen)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        ran = try c.decodeIfPresent(String.self, forKey: .ran)
        callDigest = try c.decodeIfPresent(String.self, forKey: .callDigest)
        resolutionDigest = try c.decodeIfPresent(String.self, forKey: .resolutionDigest)
        candidates = try c.decodeIfPresent([ProofCandidate].self, forKey: .candidates) ?? []
        thresholds = try c.decodeIfPresent(TierThresholds.self, forKey: .thresholds) ?? .default
        guards = try c.decodeIfPresent(ProofGuards.self, forKey: .guards) ?? ProofGuards()
        embedder = try c.decodeIfPresent(EmbedderFingerprint.self, forKey: .embedder)
        artifactHash = try c.decodeIfPresent(String.self, forKey: .artifactHash)
        steps = try c.decodeIfPresent([ProofStep].self, forKey: .steps) ?? []
        timings = try c.decodeIfPresent(ProofTimings.self, forKey: .timings) ?? ProofTimings()
        proofDigest = try c.decodeIfPresent(String.self, forKey: .proofDigest) ?? ""
    }
}

// MARK: - ProofTimer

/// Tiny utility for measuring elapsed time between proof steps.
public struct ProofTimer: Sendable {
    private var start: DispatchTime

    public init() {
        self.start = .now()
    }

    public func microsecondsSinceStart() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000)
    }

    /// Milliseconds since the timer started (or was last lapped).
    public func milliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Milliseconds since the last lap, restarting the timer.
    public mutating func lap() -> Double {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        start = now
        return elapsed
    }
}
