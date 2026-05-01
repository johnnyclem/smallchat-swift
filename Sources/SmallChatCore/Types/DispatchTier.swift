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
