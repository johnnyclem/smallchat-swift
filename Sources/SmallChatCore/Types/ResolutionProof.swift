import Foundation

// MARK: - ResolutionProof

/// A single step in a `ResolutionProof`.
///
/// Each step records a deterministic stage of resolution (cache lookup,
/// pin match, vector search, overload resolution, verification, etc.)
/// with the elapsed time so the full path can be replayed for debugging.
public struct ResolutionStep: Sendable, Codable, Equatable {
    public let stage: String
    public let detail: String
    public let outcome: Outcome
    public let elapsedMicroseconds: Int

    public enum Outcome: String, Sendable, Codable, Equatable {
        case hit
        case miss
        case skipped
        case error
    }

    public init(stage: String, detail: String, outcome: Outcome, elapsedMicroseconds: Int) {
        self.stage = stage
        self.detail = detail
        self.outcome = outcome
        self.elapsedMicroseconds = elapsedMicroseconds
    }
}

/// Ordered, replayable record of how a dispatch decision was reached.
///
/// Returned alongside dispatch results when proof tracing is enabled, and
/// embedded in `ToolRefinement` payloads so callers can see exactly why
/// no tool was confidently selected.
public struct ResolutionProof: Sendable, Codable, Equatable {
    public var steps: [ResolutionStep]
    public var finalTier: DispatchTier
    public var totalElapsedMicroseconds: Int

    public init(
        steps: [ResolutionStep] = [],
        finalTier: DispatchTier = .none,
        totalElapsedMicroseconds: Int = 0
    ) {
        self.steps = steps
        self.finalTier = finalTier
        self.totalElapsedMicroseconds = totalElapsedMicroseconds
    }

    /// Append a step. Caller is responsible for measuring elapsed time.
    public mutating func record(_ step: ResolutionStep) {
        steps.append(step)
        totalElapsedMicroseconds += step.elapsedMicroseconds
    }
}

// MARK: - ProofTimer

/// Tiny utility for measuring elapsed microseconds between proof steps.
public struct ProofTimer: Sendable {
    private let start: DispatchTime

    public init() {
        self.start = .now()
    }

    public func microsecondsSinceStart() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000)
    }
}
