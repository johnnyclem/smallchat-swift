import Foundation
import SmallChatCore

// MARK: - DispatchObserver

/// Outcome of a dispatch as observed by the runtime, used to feed back
/// adaptive thresholds.
public enum DispatchOutcome: Sendable, Equatable {
    case accepted(toolName: String, tier: DispatchTier, confidence: Double)
    case corrected(intendedTool: String, actualTool: String, tier: DispatchTier)
    case refined(intent: String, tier: DispatchTier)
}

/// KVO-style observer that records dispatch outcomes per tool class and
/// nudges thresholds based on corrections. After enough corrections for a
/// given tool class, the recommended threshold for that class rises so
/// future ambiguous matches downgrade earlier.
///
/// Mirrors the adaptive-threshold + observer mechanism in TS PR #54.
public actor DispatchObserver {

    private struct ClassStats: Sendable {
        var accepted: Int = 0
        var corrected: Int = 0
        var refined: Int = 0
        var lastConfidence: Double = 0.0
    }

    private var stats: [String: ClassStats] = [:]
    private let baseThreshold: Double
    private let maxThreshold: Double
    private let perCorrectionStep: Double

    public init(
        baseThreshold: Double = 0.85,
        maxThreshold: Double = 0.97,
        perCorrectionStep: Double = 0.02
    ) {
        self.baseThreshold = baseThreshold
        self.maxThreshold = maxThreshold
        self.perCorrectionStep = perCorrectionStep
    }

    /// Record an outcome for the given canonical tool name (provider.tool).
    public func record(_ outcome: DispatchOutcome) {
        switch outcome {
        case .accepted(let name, _, let confidence):
            var s = stats[name] ?? ClassStats()
            s.accepted += 1
            s.lastConfidence = confidence
            stats[name] = s
        case .corrected(_, let actual, _):
            var s = stats[actual] ?? ClassStats()
            s.corrected += 1
            stats[actual] = s
        case .refined(_, _):
            // Refinements aren't tied to a tool; nothing to update.
            break
        }
    }

    /// Recommended HIGH threshold for the tool class derived from
    /// observed corrections. Returns the configured base when there is no
    /// evidence to justify adjustment.
    public func recommendedThreshold(for canonicalTool: String) -> Double {
        guard let s = stats[canonicalTool] else { return baseThreshold }
        let bump = Double(s.corrected) * perCorrectionStep
        return min(maxThreshold, baseThreshold + bump)
    }

    /// Snapshot of the current per-tool counters. For diagnostics.
    public func snapshot() -> [String: (accepted: Int, corrected: Int, refined: Int)] {
        var out: [String: (accepted: Int, corrected: Int, refined: Int)] = [:]
        for (name, s) in stats {
            out[name] = (s.accepted, s.corrected, s.refined)
        }
        return out
    }
}
