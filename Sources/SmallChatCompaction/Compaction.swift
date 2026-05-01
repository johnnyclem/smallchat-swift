import Foundation
import SmallChatCore
import SmallChatShorthand

// MARK: - SmallChatCompaction
//
// Three-strategy compaction verification, ported from TS PR #57.
// "Compaction" reduces a corpus of items (claims, log lines, journal
// entries) into a smaller, equivalent corpus. Each verification strategy
// catches a different class of bug:
//
//   1. Resampling   -- sample N items pre/post; their canonical token sets
//                      should still appear somewhere in the post-corpus.
//   2. Contradiction -- if the pre-corpus contained a fact and the
//                      post-corpus contains its negation, that's a bug.
//   3. DiffInvariants -- key-set or schema-level invariants the caller
//                      declares must be preserved.

// MARK: - Items

public struct CompactionItem: Sendable, Equatable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - Report

public struct CompactionReport: Sendable, Equatable {
    public let resampling: ResamplingReport
    public let contradiction: ContradictionReport
    public let diffInvariants: DiffInvariantsReport

    public var passed: Bool {
        resampling.passed && contradiction.passed && diffInvariants.passed
    }
}

public struct ResamplingReport: Sendable, Equatable {
    public let sampledIds: [String]
    public let preservedIds: [String]
    public let dropped: [String]
    public let passed: Bool
}

public struct ContradictionReport: Sendable, Equatable {
    public let contradictions: [Contradiction]
    public var passed: Bool { contradictions.isEmpty }

    public struct Contradiction: Sendable, Equatable {
        public let preId: String
        public let postId: String
        public let preText: String
        public let postText: String
    }
}

public struct DiffInvariantsReport: Sendable, Equatable {
    public let violations: [String]
    public var passed: Bool { violations.isEmpty }
}

// MARK: - Verifier

public struct CompactionVerifier: Sendable {

    public typealias Invariant = @Sendable ([CompactionItem], [CompactionItem]) -> String?

    public let sampleSize: Int
    public let resamplingThreshold: Double
    public let invariants: [Invariant]

    public init(
        sampleSize: Int = 32,
        resamplingThreshold: Double = 0.6,
        invariants: [Invariant] = []
    ) {
        self.sampleSize = sampleSize
        self.resamplingThreshold = resamplingThreshold
        self.invariants = invariants
    }

    public func verify(before: [CompactionItem], after: [CompactionItem]) -> CompactionReport {
        let resampling = checkResampling(before: before, after: after)
        let contradiction = checkContradictions(before: before, after: after)
        let diff = checkInvariants(before: before, after: after)
        return CompactionReport(
            resampling: resampling,
            contradiction: contradiction,
            diffInvariants: diff
        )
    }

    // MARK: - Strategy 1: resampling

    /// Sample `sampleSize` items from `before` and check that each is
    /// represented in `after` -- "represented" meaning some `after` item
    /// covers the sampled token set with Jaccard >= `resamplingThreshold`.
    private func checkResampling(before: [CompactionItem], after: [CompactionItem]) -> ResamplingReport {
        let sample = deterministicSample(before, count: sampleSize)
        let afterTokens = after.map { Set(Shorthand.tokens(in: $0.text)) }

        var preserved: [String] = []
        var dropped: [String] = []
        for item in sample {
            let tokens = Set(Shorthand.tokens(in: item.text))
            let covered = afterTokens.contains { Shorthand.jaccard(tokens, $0) >= resamplingThreshold }
            if covered { preserved.append(item.id) } else { dropped.append(item.id) }
        }

        // Pass if at least 90% of sampled items are still represented.
        let passed = sample.isEmpty || Double(preserved.count) / Double(sample.count) >= 0.90
        return ResamplingReport(
            sampledIds: sample.map(\.id),
            preservedIds: preserved,
            dropped: dropped,
            passed: passed
        )
    }

    // MARK: - Strategy 2: contradictions

    /// Heuristic contradiction check. If any `after` item is a literal
    /// negation of a `before` item ("X" vs "not X" / "no X"), flag it.
    /// This is intentionally conservative -- meant to catch obvious
    /// flips, not philosophical disagreements.
    private func checkContradictions(before: [CompactionItem], after: [CompactionItem]) -> ContradictionReport {
        var found: [ContradictionReport.Contradiction] = []
        for pre in before {
            let preTokens = Set(Shorthand.tokens(in: pre.text))
            let preSentences = Shorthand.sentences(in: pre.text)
            for post in after {
                let postSentences = Shorthand.sentences(in: post.text)
                if isLiteralNegation(of: preSentences, in: postSentences),
                   !preTokens.isEmpty,
                   Shorthand.jaccard(preTokens, Set(Shorthand.tokens(in: post.text))) >= 0.6 {
                    found.append(.init(
                        preId: pre.id,
                        postId: post.id,
                        preText: pre.text,
                        postText: post.text
                    ))
                    break
                }
            }
        }
        return ContradictionReport(contradictions: found)
    }

    // MARK: - Strategy 3: diff invariants

    /// Run caller-declared invariants. Each invariant returns a non-nil
    /// string (the violation message) when it fails.
    private func checkInvariants(before: [CompactionItem], after: [CompactionItem]) -> DiffInvariantsReport {
        var violations: [String] = []
        for inv in invariants {
            if let msg = inv(before, after) { violations.append(msg) }
        }
        return DiffInvariantsReport(violations: violations)
    }

    // MARK: - Helpers

    /// Deterministic sampler: takes evenly-spaced items by index so that
    /// the same input always yields the same sample.
    private func deterministicSample(_ items: [CompactionItem], count: Int) -> [CompactionItem] {
        guard items.count > count else { return items }
        var step = items.count / count
        if step < 1 { step = 1 }
        var out: [CompactionItem] = []
        var i = 0
        while out.count < count, i < items.count {
            out.append(items[i])
            i += step
        }
        return out
    }

    private func isLiteralNegation(of preSentences: [String], in postSentences: [String]) -> Bool {
        let negationMarkers = ["not ", "no ", "never ", "isn't ", "aren't ", "doesn't ", "don't ", "won't "]
        for pre in preSentences {
            let preLower = pre.lowercased()
            for post in postSentences {
                let postLower = post.lowercased()
                for marker in negationMarkers {
                    if postLower.contains(marker), postLower.replacingOccurrences(of: marker, with: "").contains(preLower) {
                        return true
                    }
                }
            }
        }
        return false
    }
}

// MARK: - Stock invariants

public enum CompactionInvariants {
    /// Post-compaction must contain at least `minRatio * before.count` items.
    public static func minimumRetention(_ minRatio: Double) -> CompactionVerifier.Invariant {
        return { before, after in
            guard !before.isEmpty else { return nil }
            let kept = Double(after.count) / Double(before.count)
            if kept < minRatio {
                return String(format: "retention %.2f below minimum %.2f", kept, minRatio)
            }
            return nil
        }
    }

    /// Post-compaction must not introduce ids that were not in before.
    public static func noNewIds() -> CompactionVerifier.Invariant {
        return { before, after in
            let preIds = Set(before.map(\.id))
            let novel = after.filter { !preIds.contains($0.id) }.map(\.id)
            return novel.isEmpty ? nil : "introduced new ids: \(novel.joined(separator: ","))"
        }
    }
}
