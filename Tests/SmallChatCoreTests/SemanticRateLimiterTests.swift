import Foundation
import Testing
@testable import SmallChatCore

@Suite("SemanticRateLimiter")
struct SemanticRateLimiterTests {

    // MARK: - Flood Detection (Volume Cap)

    @Test("Throttles when novel intent count exceeds max")
    func throttlesOnVolumeExceeded() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 5,
            minSamplesForSimilarity: 100  // high to avoid similarity check interfering
        ))

        // Record 5 intents
        for i in 0..<5 {
            let allowed = await limiter.check("intent:\(i)")
            #expect(allowed == true)
            await limiter.record("intent:\(i)", [Float(i), 0.0, 0.0])
        }

        // 6th should be throttled
        let allowed = await limiter.check("intent:5")
        #expect(allowed == false)
    }

    @Test("Allows intents under the volume cap")
    func allowsUnderCap() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 10,
            minSamplesForSimilarity: 100
        ))

        for i in 0..<9 {
            let allowed = await limiter.check("intent:\(i)")
            #expect(allowed == true)
            await limiter.record("intent:\(i)", [Float(i)])
        }
    }

    // MARK: - Window Eviction

    @Test("Stale entries are evicted after window expires")
    func windowEviction() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 100,  // 100ms window
            maxNovelIntents: 3,
            minSamplesForSimilarity: 100
        ))

        // Fill the window
        for i in 0..<3 {
            _ = await limiter.check("intent:\(i)")
            await limiter.record("intent:\(i)", [Float(i)])
        }

        // Should be throttled now
        let throttled = await limiter.check("overflow")
        #expect(throttled == false)

        // Wait for window to expire
        try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

        // Should be allowed now after eviction
        let allowed = await limiter.check("newIntent")
        #expect(allowed == true)
    }

    // MARK: - Similarity Floor

    @Test("checkSimilarity returns false when average similarity is below floor")
    func lowSimilarityDetected() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            similarityFloor: 0.5,
            minSamplesForSimilarity: 3
        ))

        // Record orthogonal vectors (cosine similarity ~0)
        await limiter.record("a", [1.0, 0.0, 0.0])
        await limiter.record("b", [0.0, 1.0, 0.0])
        await limiter.record("c", [0.0, 0.0, 1.0])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == false)
    }

    @Test("checkSimilarity returns true when vectors are similar")
    func highSimilarityHealthy() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            similarityFloor: 0.5,
            minSamplesForSimilarity: 3
        ))

        // Record similar vectors
        await limiter.record("a", [1.0, 0.1, 0.0])
        await limiter.record("b", [1.0, 0.2, 0.0])
        await limiter.record("c", [1.0, 0.05, 0.0])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == true)
    }

    @Test("checkSimilarity returns true with insufficient samples")
    func insufficientSamplesHealthy() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            similarityFloor: 0.5,
            minSamplesForSimilarity: 10
        ))

        // Only 2 samples, below minSamplesForSimilarity
        await limiter.record("a", [1.0, 0.0, 0.0])
        await limiter.record("b", [0.0, 1.0, 0.0])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == true)
    }

    // MARK: - Entropy Detection

    @Test("Throttles when high-entropy fraction exceeds threshold")
    func highEntropyThrottles() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 1000,
            maxCanonicalLength: 10,
            entropyFraction: 0.5,
            minSamplesForSimilarity: 3
        ))

        // Record 3 high-entropy (long) canonicals
        for i in 0..<3 {
            let longCanonical = String(repeating: "x", count: 50) + "\(i)"
            _ = await limiter.check(longCanonical)
            await limiter.record(longCanonical, [Float(i)])
        }

        // Now check with another long canonical — should be throttled (3/3 = 100% > 50%)
        let longCanonical = String(repeating: "y", count: 50)
        let allowed = await limiter.check(longCanonical)
        #expect(allowed == false)
    }

    @Test("Does not throttle when entropy fraction is low")
    func lowEntropyAllowed() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 1000,
            maxCanonicalLength: 10,
            entropyFraction: 0.5,
            minSamplesForSimilarity: 5
        ))

        // Record 2 short + 1 long (1/3 = 33% < 50%)
        _ = await limiter.check("short1")
        await limiter.record("short1", [1.0])
        _ = await limiter.check("short2")
        await limiter.record("short2", [1.0])
        let longCanonical = String(repeating: "x", count: 50)
        _ = await limiter.check(longCanonical)
        await limiter.record(longCanonical, [1.0])

        let allowed = await limiter.check("short3")
        #expect(allowed == true)
    }

    // MARK: - Metrics

    @Test("getMetrics reports correct state")
    func metricsReportCorrectly() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 100,
            similarityFloor: 0.3,
            minSamplesForSimilarity: 100
        ))

        await limiter.record("a", [1.0, 0.0])
        await limiter.record("b", [0.0, 1.0])

        let metrics = await limiter.getMetrics()
        #expect(metrics.novelCount == 2)
        #expect(metrics.throttled == false)
    }

    // MARK: - Reset

    @Test("reset clears all state")
    func resetClearsState() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 3,
            minSamplesForSimilarity: 100
        ))

        for i in 0..<3 {
            _ = await limiter.check("i:\(i)")
            await limiter.record("i:\(i)", [Float(i)])
        }

        // Throttled
        #expect(await limiter.check("overflow") == false)

        // Reset and verify cleared
        await limiter.reset()
        #expect(await limiter.check("fresh") == true)

        let metrics = await limiter.getMetrics()
        #expect(metrics.novelCount == 0)
    }
}
