import Foundation
import Testing
@testable import SmallChatImportance

@Suite("Importance three-signal detector")
struct ImportanceTests {

    private func makeDetector(now: TimeInterval) -> ImportanceDetector {
        ImportanceDetector(
            weights: .balanced,
            recencyHalfLifeSeconds: 1, // 1-second half-life makes recency easy to test
            now: { now }
        )
    }

    @Test("Recency: an item observed `now` is weighted higher than one observed long ago")
    func recencyFavorsRecent() {
        let detector = makeDetector(now: 100)
        let recent = ImportanceCandidate(id: "r", text: "alpha beta gamma delta", timestamp: 100)
        let old = ImportanceCandidate(id: "o", text: "alpha beta gamma delta", timestamp: 0)
        let corpus = [recent, old]

        let recentScore = detector.score(recent, corpus: corpus)
        let oldScore = detector.score(old, corpus: corpus)
        #expect(recentScore.recency > oldScore.recency)
        #expect(recentScore.recency > 0.99)   // age 0
        #expect(oldScore.recency < 0.01)      // age >> half-life
    }

    @Test("Novelty rewards items with no token overlap to the rest of the corpus")
    func noveltyRewardsUnique() {
        let detector = makeDetector(now: 100)
        let unique = ImportanceCandidate(id: "u", text: "kangaroo wallaby koala wombat", timestamp: 100)
        let common = ImportanceCandidate(id: "c", text: "alpha beta gamma delta", timestamp: 100)
        let twin = ImportanceCandidate(id: "t", text: "alpha beta gamma delta", timestamp: 100)
        let corpus = [unique, common, twin]

        let uniqueScore = detector.score(unique, corpus: corpus)
        let commonScore = detector.score(common, corpus: corpus)
        #expect(uniqueScore.novelty > commonScore.novelty)
        #expect(uniqueScore.novelty == 1) // no overlap with anyone
    }

    @Test("Centrality rewards items that share tokens with many others")
    func centralityRewardsShared() {
        let detector = makeDetector(now: 100)
        let central = ImportanceCandidate(id: "c", text: "shared common token", timestamp: 100)
        let neighbor1 = ImportanceCandidate(id: "n1", text: "shared common one", timestamp: 100)
        let neighbor2 = ImportanceCandidate(id: "n2", text: "shared common two", timestamp: 100)
        let isolated = ImportanceCandidate(id: "i", text: "isolated foreign random", timestamp: 100)

        let corpus = [central, neighbor1, neighbor2, isolated]
        let centralScore = detector.score(central, corpus: corpus)
        let isolatedScore = detector.score(isolated, corpus: corpus)
        #expect(centralScore.centrality > isolatedScore.centrality)
    }

    @Test("Combined score is in [0, 1] and rank() sorts descending")
    func rankSorted() {
        let detector = makeDetector(now: 100)
        let candidates = [
            ImportanceCandidate(id: "a", text: "one two three", timestamp: 100),
            ImportanceCandidate(id: "b", text: "four five six", timestamp: 50),
            ImportanceCandidate(id: "c", text: "seven eight nine", timestamp: 0),
        ]
        let ranked = detector.rank(candidates)
        #expect(ranked.count == 3)
        for i in 1..<ranked.count {
            #expect(ranked[i - 1].score >= ranked[i].score)
        }
        for s in ranked {
            #expect(s.score >= 0)
            #expect(s.score <= 1)
        }
    }
}
