import Foundation
import SmallChatCore
import SmallChatShorthand

// MARK: - SmallChatImportance
//
// Three-signal importance detection, ported from TS PR #55. Each signal
// is independently configurable and weighted; the combined score is
// normalized to [0, 1].
//
// Signals:
//   1. Recency  -- exponential decay over wall-clock age.
//   2. Centrality -- co-occurrence centrality of the candidate's tokens
//      against the current corpus (proxy for "how connected to other
//      items" without requiring a real graph).
//   3. Novelty  -- 1 - max(jaccard) against existing items, so things
//      that look like nothing in the corpus rank higher.
//
// Domain-agnostic: the corpus you pass in is just a [String]. Plug it in
// from claims, log lines, journal entries, anything textual.

public struct ImportanceCandidate: Sendable, Equatable {
    public let id: String
    public let text: String
    /// Wall-clock timestamp the candidate was observed, in seconds since
    /// the Unix epoch.
    public let timestamp: TimeInterval

    public init(id: String, text: String, timestamp: TimeInterval) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ImportanceWeights: Sendable, Equatable {
    public var recency: Double
    public var centrality: Double
    public var novelty: Double

    public init(recency: Double = 1.0/3.0, centrality: Double = 1.0/3.0, novelty: Double = 1.0/3.0) {
        self.recency = recency
        self.centrality = centrality
        self.novelty = novelty
    }

    public static let balanced = ImportanceWeights()
}

public struct ImportanceScore: Sendable, Equatable {
    public let id: String
    public let score: Double
    public let recency: Double
    public let centrality: Double
    public let novelty: Double

    public init(id: String, score: Double, recency: Double, centrality: Double, novelty: Double) {
        self.id = id
        self.score = score
        self.recency = recency
        self.centrality = centrality
        self.novelty = novelty
    }
}

// MARK: - Detector

public struct ImportanceDetector: Sendable {

    public let weights: ImportanceWeights
    /// Half-life of the recency signal in seconds. Default ~7 days.
    public let recencyHalfLifeSeconds: Double
    /// Reference time used to compute recency. Pin to a known point for
    /// reproducible scoring; defaults to "now".
    public let now: () -> TimeInterval

    public init(
        weights: ImportanceWeights = .balanced,
        recencyHalfLifeSeconds: Double = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.weights = weights
        self.recencyHalfLifeSeconds = recencyHalfLifeSeconds
        self.now = now
    }

    /// Score a single candidate against a corpus. The corpus is the
    /// full set of comparable items (their `text`); the candidate may or
    /// may not be a member -- if it is, it is excluded from the
    /// centrality and novelty computations.
    public func score(_ candidate: ImportanceCandidate, corpus: [ImportanceCandidate]) -> ImportanceScore {
        let r = recencyScore(timestamp: candidate.timestamp)
        let c = centralityScore(candidate: candidate, corpus: corpus)
        let n = noveltyScore(candidate: candidate, corpus: corpus)

        // Normalize the combined score by the sum of weights so callers
        // who set non-balanced weights still get a [0, 1] result.
        let totalWeight = max(weights.recency + weights.centrality + weights.novelty, 0.0001)
        let combined = (weights.recency * r + weights.centrality * c + weights.novelty * n) / totalWeight

        return ImportanceScore(
            id: candidate.id,
            score: clamp01(combined),
            recency: r,
            centrality: c,
            novelty: n
        )
    }

    /// Score every candidate against the full corpus. Convenience for
    /// batch ranking.
    public func rank(_ candidates: [ImportanceCandidate]) -> [ImportanceScore] {
        candidates
            .map { score($0, corpus: candidates) }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Signals

    private func recencyScore(timestamp: TimeInterval) -> Double {
        let age = max(now() - timestamp, 0)
        // Exponential decay: e^(-ln2 * age / halfLife) so age == halfLife yields 0.5.
        let lambda = log(2.0) / max(recencyHalfLifeSeconds, 1)
        return exp(-lambda * age)
    }

    /// Centrality: average Jaccard overlap of the candidate's tokens
    /// against every other corpus item. High overlap means the candidate
    /// touches many other items; we treat that as "connected".
    private func centralityScore(candidate: ImportanceCandidate, corpus: [ImportanceCandidate]) -> Double {
        let candidateTokens = Set(Shorthand.tokens(in: candidate.text))
        guard !candidateTokens.isEmpty else { return 0 }

        var sum = 0.0
        var count = 0
        for other in corpus where other.id != candidate.id {
            let otherTokens = Set(Shorthand.tokens(in: other.text))
            if otherTokens.isEmpty { continue }
            sum += Shorthand.jaccard(candidateTokens, otherTokens)
            count += 1
        }
        return count == 0 ? 0 : clamp01(sum / Double(count))
    }

    /// Novelty: 1 - max similarity to any other corpus item.
    private func noveltyScore(candidate: ImportanceCandidate, corpus: [ImportanceCandidate]) -> Double {
        let candidateTokens = Set(Shorthand.tokens(in: candidate.text))
        guard !candidateTokens.isEmpty else { return 1 }

        var maxSim = 0.0
        for other in corpus where other.id != candidate.id {
            let otherTokens = Set(Shorthand.tokens(in: other.text))
            if otherTokens.isEmpty { continue }
            let s = Shorthand.jaccard(candidateTokens, otherTokens)
            if s > maxSim { maxSim = s }
        }
        return clamp01(1 - maxSim)
    }
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
