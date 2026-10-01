import Foundation
import SmallChatCore

// MARK: - Dispatch policy (@smallchat/core 1.0 runtime/policy.ts)

/// The one rule set that decides whether a resolved tool may run without
/// the caller choosing it explicitly.
///
/// It is evaluated on every path that can lead to execution: dispatch by
/// id, pinned phrases, cache hits, vector and overload candidates, protocol
/// conformance, and each sub-intent of a decomposition (which is dispatched
/// through the same pipeline). A path that is denied does not fall back to
/// some other way of running the tool; the outcome is needs-disambiguation
/// and the caller picks a tool id.
///
/// Rules, in order:
///   1. Dispatch by exact tool id is always allowed (the caller named it).
///   2. Intent pins: an `exact` pin only accepts its pinned phrase (the pin
///      canonical or an alias, compared with `normalizePinPhrase`); an
///      `elevated` pin only accepts a cosine similarity, computed from this
///      intent's own embedding, at or above its threshold.
///   3. Destructive tools (`isDestructive`) run only from a pinned phrase or
///      an EXACT-tier similarity computed from this intent's own embedding
///      -- never from a cache hit or a boosted score.
///   4. Below HIGH (MEDIUM/LOW), a candidate runs only if an LLM verifier
///      approved it for this intent, unless `requireLLMForSubHighDispatch`
///      is off.
///   5. Below LOW, nothing runs.
public struct DispatchPolicyOptions: Sendable, Equatable {
    public var thresholds: TierThresholds
    /// Rule 4. Default true.
    public var requireLLMForSubHighDispatch: Bool
    /// Treat tools that declare no annotations at all as destructive.
    public var treatUnannotatedAsDestructive: Bool

    public init(thresholds: TierThresholds = .default, requireLLMForSubHighDispatch: Bool = true, treatUnannotatedAsDestructive: Bool = false) {
        self.thresholds = thresholds
        self.requireLLMForSubHighDispatch = requireLLMForSubHighDispatch
        self.treatUnannotatedAsDestructive = treatUnannotatedAsDestructive
    }
}

/// How one intent pin applies to one candidate.
public struct PinState: Sendable, Equatable {
    public var canonical: String
    public var policy: IntentPinPolicy
    /// Whether the pin's condition holds for this intent
    public var satisfied: Bool
    /// For `elevated`: the similarity that was checked (nil: none from this intent's embedding)
    public var similarity: Double?
    /// For `elevated`: the bar
    public var requiredThreshold: Double?

    public init(canonical: String, policy: IntentPinPolicy, satisfied: Bool, similarity: Double? = nil, requiredThreshold: Double? = nil) {
        self.canonical = canonical
        self.policy = policy
        self.satisfied = satisfied
        self.similarity = similarity
        self.requiredThreshold = requiredThreshold
    }
}

/// One candidate as the policy sees it.
public struct PolicyInput: Sendable {
    public enum Mode: Sendable { case id, intent }
    /// `.id`: the caller named the tool; `.intent`: resolution chose it
    public var mode: Mode
    public var toolId: String
    public var annotations: ToolAnnotations?
    public var source: CandidateSource
    /// Score the candidate was ranked by
    public var score: Double
    /// Similarity from this intent's own embedding, or nil when not vector-derived
    public var similarity: Double?
    /// Whether an LLM verifier approved this tool for this intent
    public var llmApproved: Bool
    /// Pins that apply to this tool
    public var pins: [PinState]

    public init(mode: Mode, toolId: String, annotations: ToolAnnotations?, source: CandidateSource, score: Double, similarity: Double?, llmApproved: Bool, pins: [PinState]) {
        self.mode = mode
        self.toolId = toolId
        self.annotations = annotations
        self.source = source
        self.score = score
        self.similarity = similarity
        self.llmApproved = llmApproved
        self.pins = pins
    }
}

/// The policy's answer for one candidate.
public struct PolicyVerdict: Sendable, Equatable {
    public enum Code: String, Sendable {
        case allow
        case pinExactRequired = "pin-exact-required"
        case pinElevatedRequired = "pin-elevated-required"
        case destructiveNeedsExact = "destructive-needs-exact"
        case needsLLMVerifier = "needs-llm-verifier"
        case belowThreshold = "below-threshold"
    }

    public var allow: Bool
    public var code: Code
    /// One sentence, suitable for a proof step or an error shown to a model
    public var reason: String
    /// The tier the verdict was computed at
    public var tier: DispatchTier

    /// The proof decision code of a denial.
    public var decision: DecisionCode {
        DecisionCode(rawValue: code.rawValue) ?? .belowThreshold
    }
}

/// Whether a tool counts as destructive. A read-only tool never is; an
/// explicit `destructiveHint` wins; a tool that says it is not read-only
/// but omits `destructiveHint` is destructive (the MCP default for that
/// case); a tool with neither hint follows `treatUnannotatedAsDestructive`.
public func isDestructive(_ annotations: ToolAnnotations?, treatUnannotatedAsDestructive: Bool) -> Bool {
    if annotations?.readOnlyHint == true { return false }
    if let destructive = annotations?.destructiveHint { return destructive }
    if annotations?.readOnlyHint == false { return true }
    return treatUnannotatedAsDestructive
}

/// Apply the dispatch policy (see `DispatchPolicyOptions`) to one candidate.
public func evaluateDispatchPolicy(_ input: PolicyInput, options: DispatchPolicyOptions) -> PolicyVerdict {
    let tier = computeTier(input.score, thresholds: options.thresholds)

    if input.mode == .id {
        return PolicyVerdict(allow: true, code: .allow, reason: "\(input.toolId) was named by exact tool id", tier: .exact)
    }

    for pin in input.pins where !pin.satisfied {
        if pin.policy == .exact {
            return PolicyVerdict(
                allow: false,
                code: .pinExactRequired,
                reason: "\(input.toolId) is pinned 'exact' (\(pin.canonical)): only its pinned phrases dispatch to it",
                tier: tier
            )
        }
        let seen = pin.similarity.map { "similarity \(fixed3($0))" } ?? "no own-embedding similarity"
        let bar = pin.requiredThreshold.map { ecmaNumber($0) } ?? "its threshold"
        return PolicyVerdict(
            allow: false,
            code: .pinElevatedRequired,
            reason: "\(input.toolId) is pinned 'elevated' (\(pin.canonical)): needs similarity >= \(bar), got \(seen)",
            tier: tier
        )
    }

    if isDestructive(input.annotations, treatUnannotatedAsDestructive: options.treatUnannotatedAsDestructive) {
        let exactPhrase = input.source == .pin
        let exactSimilarity = input.similarity.map { computeTier($0, thresholds: options.thresholds) == .exact } ?? false
        if !exactPhrase && !exactSimilarity {
            let seen = input.similarity.map { "similarity \(fixed3($0))" } ?? "a \(input.source.rawValue) match"
            return PolicyVerdict(
                allow: false,
                code: .destructiveNeedsExact,
                reason: "\(input.toolId) is destructive: it runs only by exact tool id, a pinned phrase, or EXACT similarity (>= \(ecmaNumber(options.thresholds.exact))); got \(seen)",
                tier: tier
            )
        }
    }

    if tier == .none {
        return PolicyVerdict(
            allow: false,
            code: .belowThreshold,
            reason: "\(input.toolId) scored \(fixed3(input.score)), below the LOW threshold (\(ecmaNumber(options.thresholds.low)))",
            tier: tier
        )
    }

    if (tier == .medium || tier == .low) && options.requireLLMForSubHighDispatch && !input.llmApproved {
        return PolicyVerdict(
            allow: false,
            code: .needsLLMVerifier,
            reason: "\(input.toolId) scored \(fixed3(input.score)) (\(tier.rawValue)); below HIGH a tool runs only after an LLM verifier approves it",
            tier: tier
        )
    }

    return PolicyVerdict(allow: true, code: .allow, reason: "\(input.toolId) allowed at \(tier.rawValue) (\(fixed3(input.score)))", tier: tier)
}

/// `x.toFixed(3)`.
func fixed3(_ x: Double) -> String {
    String(format: "%.3f", x)
}

/// A number as ECMAScript prints it (0.95, not 0.9500).
func ecmaNumber(_ x: Double) -> String {
    (try? ecmaScriptNumberString(x)) ?? String(x)
}
