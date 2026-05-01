import Testing
@testable import SmallChatCompaction

@Suite("Compaction verification")
struct CompactionTests {

    private func items(_ pairs: [(String, String)]) -> [CompactionItem] {
        pairs.map { CompactionItem(id: $0.0, text: $0.1) }
    }

    // MARK: - Resampling

    @Test("Resampling: identity compaction passes")
    func resamplingIdentity() {
        let before = items([
            ("1", "alpha bravo charlie"),
            ("2", "delta echo foxtrot"),
            ("3", "golf hotel india"),
        ])
        let verifier = CompactionVerifier(sampleSize: 3)
        let report = verifier.verify(before: before, after: before)
        #expect(report.resampling.passed)
        #expect(report.passed)
    }

    @Test("Resampling: empty after fails")
    func resamplingEmptyAfter() {
        let before = items([
            ("1", "alpha bravo charlie"),
            ("2", "delta echo foxtrot"),
        ])
        let verifier = CompactionVerifier(sampleSize: 2)
        let report = verifier.verify(before: before, after: [])
        #expect(!report.resampling.passed)
        #expect(!report.passed)
    }

    // MARK: - Contradictions

    @Test("Contradiction: literal negation flagged")
    func contradictionFlagged() {
        let before = items([
            ("1", "the deploy succeeded"),
        ])
        let after = items([
            ("1c", "the deploy did not the deploy succeeded"),
        ])
        let verifier = CompactionVerifier(sampleSize: 1)
        let report = verifier.verify(before: before, after: after)
        #expect(!report.contradiction.passed)
    }

    @Test("Contradiction: paraphrase doesn't flag")
    func contradictionParaphrase() {
        let before = items([
            ("1", "deploy succeeded for service A"),
        ])
        let after = items([
            ("1c", "deploy succeeded service A"),
        ])
        let verifier = CompactionVerifier(sampleSize: 1)
        let report = verifier.verify(before: before, after: after)
        #expect(report.contradiction.passed)
    }

    // MARK: - Invariants

    @Test("minimumRetention invariant trips when too aggressive")
    func minimumRetentionTrips() {
        let before = items([
            ("1", "a"), ("2", "b"), ("3", "c"), ("4", "d"),
        ])
        let after = items([("1", "a")])
        let verifier = CompactionVerifier(
            sampleSize: 4,
            invariants: [CompactionInvariants.minimumRetention(0.5)]
        )
        let report = verifier.verify(before: before, after: after)
        #expect(!report.diffInvariants.passed)
    }

    @Test("noNewIds invariant trips when after introduces unseen id")
    func noNewIds() {
        let before = items([("1", "x")])
        let after = items([("1", "x"), ("2", "y")])
        let verifier = CompactionVerifier(
            sampleSize: 1,
            invariants: [CompactionInvariants.noNewIds()]
        )
        let report = verifier.verify(before: before, after: after)
        #expect(!report.diffInvariants.passed)
    }
}
