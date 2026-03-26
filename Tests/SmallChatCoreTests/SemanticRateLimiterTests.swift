import Testing
import Foundation
@testable import SmallChatCore

@Suite("SemanticRateLimiter")
struct SemanticRateLimiterTests {

    // MARK: - Flood detection (volume cap)

    @Test("Throttles after exceeding maxNovelIntents")
    func throttlesOnVolumeCap() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 5,
            similarityFloor: 0.0,
            minSamplesForSimilarity: 100
        ))

        for i in 0..<5 {
            let allowed = await limiter.check("intent:\(i)")
            #expect(allowed == true)
            await limiter.record("intent:\(i)", [Float(i), 0, 0])
        }

        // 6th intent should be throttled
        let throttled = await limiter.check("intent:overflow")
        #expect(throttled == false)
    }

    @Test("Metrics reflect throttled state")
    func metricsReflectThrottled() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 3,
            similarityFloor: 0.0,
            minSamplesForSimilarity: 100
        ))

        for i in 0..<3 {
            await limiter.record("x\(i)", [Float(i), 0, 0])
        }

        let metrics = await limiter.getMetrics()
        #expect(metrics.novelCount == 3)
        #expect(metrics.throttled == true)
    }

    // MARK: - Window eviction

    @Test("Window eviction restores capacity")
    func windowEvictionRestoresCapacity() async {
        // Use a very short window (1ms) to test eviction
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 1,
            maxNovelIntents: 2,
            similarityFloor: 0.0,
            minSamplesForSimilarity: 100
        ))

        await limiter.record("a", [1, 0, 0])
        await limiter.record("b", [0, 1, 0])

        // Wait for window to expire
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let allowed = await limiter.check("c")
        #expect(allowed == true)
    }

    // MARK: - Similarity floor

    @Test("Low average similarity triggers throttle via checkSimilarity")
    func lowSimilarityThrottles() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 1000,
            similarityFloor: 0.5,
            minSamplesForSimilarity: 3
        ))

        // Record orthogonal vectors (cosine similarity = 0)
        await limiter.record("a", [1, 0, 0])
        await limiter.record("b", [0, 1, 0])
        await limiter.record("c", [0, 0, 1])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == false)
    }

    @Test("High average similarity passes checkSimilarity")
    func highSimilarityPasses() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 1000,
            similarityFloor: 0.5,
            minSamplesForSimilarity: 3
        ))

        // Record nearly identical vectors
        await limiter.record("a", [1, 0.1, 0])
        await limiter.record("b", [1, 0.2, 0])
        await limiter.record("c", [1, 0.15, 0])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == true)
    }

    @Test("checkSimilarity returns true with insufficient samples")
    func insufficientSamplesReturnsHealthy() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            minSamplesForSimilarity: 10
        ))

        await limiter.record("a", [1, 0, 0])
        await limiter.record("b", [0, 1, 0])

        let healthy = await limiter.checkSimilarity()
        #expect(healthy == true)
    }

    // MARK: - High entropy detection

    @Test("High entropy fraction triggers throttle")
    func highEntropyThrottles() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            windowMs: 60_000,
            maxNovelIntents: 1000,
            similarityFloor: 0.0,
            minSamplesForSimilarity: 2,
            maxCanonicalLength: 10,
            entropyFraction: 0.5
        ))

        // Record 3 entries, 2 with long canonicals (high entropy)
        await limiter.record(String(repeating: "x", count: 50), [1, 0, 0])
        await limiter.record(String(repeating: "y", count: 50), [0, 1, 0])
        await limiter.record("short", [0, 0, 1])

        // 2/3 high entropy > 0.5 threshold
        let allowed = await limiter.check("next")
        #expect(allowed == false)
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func resetClearsState() async {
        let limiter = SemanticRateLimiter(options: SemanticRateLimiterOptions(
            maxNovelIntents: 2
        ))

        await limiter.record("a", [1, 0, 0])
        await limiter.record("b", [0, 1, 0])

        await limiter.reset()

        let metrics = await limiter.getMetrics()
        #expect(metrics.novelCount == 0)
        #expect(metrics.throttled == false)

        let allowed = await limiter.check("c")
        #expect(allowed == true)
    }
}
