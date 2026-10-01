// MARK: - DispatchTier

/// Confidence tier of a resolution (spec/ranking in @smallchat/core).
///
/// The dispatch policy (`evaluateDispatchPolicy`) decides what each tier
/// may do:
///   - `.exact` / `.high` -- a resolved tool may run
///   - `.medium` / `.low` -- runs only after an LLM verifier approves it
///     (unless `requireLLMForSubHighDispatch` is off); LOW may decompose
///   - `.none`            -- never runs; the result offers refinement options
/// Destructive tools additionally need EXACT similarity or an exact tool id.
public enum DispatchTier: String, Sendable, Codable, Equatable, CaseIterable {
    case exact
    case high
    case medium
    case low
    case none
}

// MARK: - Thresholds, quantization, ranking

/// Tier thresholds. The defaults are the suite's (spec/ranking):
/// EXACT >= 0.95, HIGH >= 0.85, MEDIUM >= 0.75, LOW >= 0.60, else NONE.
public struct TierThresholds: Sendable, Codable, Equatable {
    public var exact: Double
    public var high: Double
    public var medium: Double
    public var low: Double

    public init(exact: Double = 0.95, high: Double = 0.85, medium: Double = 0.75, low: Double = 0.60) {
        self.exact = exact
        self.high = high
        self.medium = medium
        self.low = low
    }

    /// The suite defaults.
    public static let `default` = TierThresholds()
}

/// Scores are compared at this resolution (4 decimal places).
public let scoreQuantum = 1e-4

/// A score rounded to 4 decimal places (half away from zero) and clamped
/// to [0, 1]; a non-finite score is 0. Every score is quantized before it
/// is ranked or compared with a threshold, so vector backends and
/// platforms that differ in the last bits of a cosine similarity reach the
/// same outcome.
public func quantizeScore(_ score: Double) -> Double {
    guard score.isFinite else { return 0 }
    return min(1, max(0, (score * 1e4).rounded() / 1e4))
}

/// The deterministic candidate order: higher quantized score first, then
/// canonical tool id by UTF-16 code units, ascending. True when `a` ranks
/// before `b`.
public func rankedBefore(score a: Double, toolId idA: String, score b: Double, toolId idB: String) -> Bool {
    let qa = quantizeScore(a), qb = quantizeScore(b)
    if qa != qb { return qa > qb }
    return idA.utf16.lexicographicallyPrecedes(idB.utf16)
}

/// The tier of a (quantized) score.
public func computeTier(_ confidence: Double, thresholds: TierThresholds = .default) -> DispatchTier {
    if confidence >= thresholds.exact { return .exact }
    if confidence >= thresholds.high { return .high }
    if confidence >= thresholds.medium { return .medium }
    if confidence >= thresholds.low { return .low }
    return .none
}

// MARK: - DispatchConfig

/// The dispatch policy's knobs. Defaults match @smallchat/core 1.0.
public struct DispatchConfig: Sendable, Codable, Equatable {
    /// Tier thresholds (compared with quantized scores).
    public var thresholds: TierThresholds
    /// Verify every dispatch below EXACT (not only below HIGH), and raise
    /// the candidate floor from LOW to MEDIUM. Learned and cached
    /// resolutions below EXACT are not used.
    public var strict: Bool
    /// Below HIGH (MEDIUM/LOW) a resolved tool runs only when an LLM
    /// verifier approved it for the intent; otherwise the outcome is
    /// needs-disambiguation. Turn off to let schema/keyword verification
    /// alone pass a MEDIUM/LOW match.
    public var requireLLMForSubHighDispatch: Bool
    /// Treat tools that declare no MCP annotations as destructive: they then
    /// run only by exact tool id, a pinned phrase or EXACT similarity.
    public var treatUnannotatedAsDestructive: Bool
    /// How many levels deep LOW-tier decomposition may go.
    public var maxDecompositionDepth: Int
    /// Cap on sub-intents dispatched (at any depth) for one request.
    public var maxSubDispatches: Int

    public init(
        thresholds: TierThresholds = .default,
        strict: Bool = false,
        requireLLMForSubHighDispatch: Bool = true,
        treatUnannotatedAsDestructive: Bool = false,
        maxDecompositionDepth: Int = 2,
        maxSubDispatches: Int = 16
    ) {
        self.thresholds = thresholds
        self.strict = strict
        self.requireLLMForSubHighDispatch = requireLLMForSubHighDispatch
        self.treatUnannotatedAsDestructive = treatUnannotatedAsDestructive
        self.maxDecompositionDepth = maxDecompositionDepth
        self.maxSubDispatches = maxSubDispatches
    }

    /// Lower bound for `.exact`.
    public var exactThreshold: Double { thresholds.exact }
    /// Lower bound for `.high`.
    public var highThreshold: Double { thresholds.high }
    /// Lower bound for `.medium`.
    public var mediumThreshold: Double { thresholds.medium }
    /// Lower bound for `.low`. Below this is `.none`.
    public var lowThreshold: Double { thresholds.low }

    /// Thresholds recalibrated for `all-MiniLM-L6-v2` (and similarly
    /// "low-contrast") sentence embedders, against which clear correct-tool
    /// paraphrases commonly score 0.60-0.74. A Swift-only preset: the suite
    /// conformance vectors use the defaults. EXACT is lower here too, so
    /// destructive tools need less similarity to run by intent; validate
    /// against your own toolkit before relying on it. See
    /// johnnyclem/smallchat-swift#36.
    public static let miniLM = DispatchConfig(
        thresholds: TierThresholds(exact: 0.92, high: 0.75, medium: 0.60, low: 0.40)
    )

    /// The tier of a raw score: quantized, then compared with the thresholds.
    public func tier(for confidence: Double) -> DispatchTier {
        computeTier(quantizeScore(confidence), thresholds: thresholds)
    }
}
