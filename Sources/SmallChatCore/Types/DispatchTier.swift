// MARK: - DispatchTier

/// Confidence tier for a dispatch decision.
///
/// Each tier triggers a distinct runtime behavior:
///   - `.exact` / `.high`  -- dispatch directly
///   - `.medium`           -- run pre-flight verification before dispatch
///   - `.low`              -- decompose the intent into sub-intents
///   - `.none`             -- emit a `ToolRefinement` (tool_refinement_needed)
///
/// Mirrors the 0.4.0 TS contract introduced in
/// johnnyclem/smallchat#54 ("Tool Selection Errors: Solved").
public enum DispatchTier: String, Sendable, Codable, Equatable, CaseIterable {
    case exact
    case high
    case medium
    case low
    case none
}

// MARK: - DispatchConfig

/// Tunable knobs that govern tier classification and per-tier behavior.
///
/// Defaults mirror the TS reference. The vector-search threshold defaults
/// to 0.60 (down from 0.75 in 0.3.0) so that more candidates make it past
/// the initial filter and into the tiered classifier.
public struct DispatchConfig: Sendable, Codable, Equatable {
    /// Minimum cosine similarity to consider a candidate at all.
    public var vectorSearchThreshold: Double
    /// Lower bound for `.exact` (typically pin matches or cache hits).
    public var exactThreshold: Double
    /// Lower bound for `.high`.
    public var highThreshold: Double
    /// Lower bound for `.medium`.
    public var mediumThreshold: Double
    /// Lower bound for `.low`. Below this is `.none`.
    public var lowThreshold: Double
    /// Maximum gap between top-1 and top-2 confidence before a tier
    /// is downgraded for ambiguity.
    public var ambiguityGap: Double
    /// When true, MEDIUM dispatches run pre-flight verification.
    public var enableVerification: Bool
    /// When true, LOW dispatches attempt intent decomposition.
    public var enableDecomposition: Bool
    /// When true, NONE dispatches emit a `ToolRefinement` payload.
    public var enableRefinement: Bool
    /// When true, ambiguity at any tier is treated as an error.
    /// Set by the compiler `--strict` flag.
    public var strict: Bool

    public init(
        vectorSearchThreshold: Double = 0.60,
        exactThreshold: Double = 0.98,
        highThreshold: Double = 0.85,
        mediumThreshold: Double = 0.70,
        lowThreshold: Double = 0.55,
        ambiguityGap: Double = 0.05,
        enableVerification: Bool = true,
        enableDecomposition: Bool = true,
        enableRefinement: Bool = true,
        strict: Bool = false
    ) {
        self.vectorSearchThreshold = vectorSearchThreshold
        self.exactThreshold = exactThreshold
        self.highThreshold = highThreshold
        self.mediumThreshold = mediumThreshold
        self.lowThreshold = lowThreshold
        self.ambiguityGap = ambiguityGap
        self.enableVerification = enableVerification
        self.enableDecomposition = enableDecomposition
        self.enableRefinement = enableRefinement
        self.strict = strict
    }

    /// Thresholds recalibrated for `all-MiniLM-L6-v2` (and similarly
    /// "low-contrast") sentence embedders.
    ///
    /// The library defaults were tuned against a higher-contrast embedding
    /// space; against MiniLM cosine similarities, clear correct-tool
    /// paraphrases commonly score 0.60-0.74, which the default thresholds
    /// classify as `.low` -- triggering decomposition/refinement for matches
    /// that are, in fact, unambiguous. This preset shifts the tier bands
    /// down to match MiniLM's observed score distribution. Validate against
    /// your own toolkit before relying on it in production; embedding-space
    /// contrast varies with corpus size and tool-description style. See
    /// johnnyclem/smallchat-swift#36.
    public static let miniLM = DispatchConfig(
        vectorSearchThreshold: 0.45,
        exactThreshold: 0.92,
        highThreshold: 0.75,
        mediumThreshold: 0.60,
        lowThreshold: 0.40
    )

    /// Classify a confidence value into a tier, considering the gap to the
    /// runner-up candidate (if any). When `runnerUp` is closer than
    /// `ambiguityGap`, downgrade by one tier.
    public func tier(for confidence: Double, runnerUp: Double? = nil) -> DispatchTier {
        let gap = runnerUp.map { confidence - $0 } ?? .infinity
        let ambiguous = gap < ambiguityGap

        let raw: DispatchTier
        switch confidence {
        case exactThreshold...:    raw = .exact
        case highThreshold...:     raw = .high
        case mediumThreshold...:   raw = .medium
        case lowThreshold...:      raw = .low
        default:                   raw = .none
        }

        if !ambiguous { return raw }

        // One-step downgrade for ambiguous results.
        switch raw {
        case .exact:  return .high
        case .high:   return .medium
        case .medium: return .low
        case .low:    return .none
        case .none:   return .none
        }
    }
}

// MARK: - Thresholds, quantization, ranking (spec/ranking in @smallchat/core)

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
