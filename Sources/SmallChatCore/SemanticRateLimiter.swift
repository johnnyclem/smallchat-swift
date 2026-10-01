import Foundation

public struct SemanticRateLimiterOptions: Sendable {
    public var windowMs: Int
    public var maxNovelIntents: Int
    public var similarityFloor: Float
    public var minSamplesForSimilarity: Int
    public var maxCanonicalLength: Int
    public var entropyFraction: Double

    public init(
        windowMs: Int = 60_000,
        maxNovelIntents: Int = 100,
        similarityFloor: Float = 0.3,
        minSamplesForSimilarity: Int = 10,
        maxCanonicalLength: Int = 200,
        entropyFraction: Double = 0.5
    ) {
        self.windowMs = windowMs
        self.maxNovelIntents = maxNovelIntents
        self.similarityFloor = similarityFloor
        self.minSamplesForSimilarity = minSamplesForSimilarity
        self.maxCanonicalLength = maxCanonicalLength
        self.entropyFraction = entropyFraction
    }
}

public struct FloodingMetrics: Sendable {
    public let novelCount: Int
    public let averageSimilarity: Float
    public let highEntropyFraction: Double
    public let throttled: Bool
    public let windowResetsIn: Int  // milliseconds

    public init(
        novelCount: Int,
        averageSimilarity: Float,
        highEntropyFraction: Double,
        throttled: Bool,
        windowResetsIn: Int
    ) {
        self.novelCount = novelCount
        self.averageSimilarity = averageSimilarity
        self.highEntropyFraction = highEntropyFraction
        self.throttled = throttled
        self.windowResetsIn = windowResetsIn
    }
}

/// Why an intent may or may not be embedded.
public enum RateLimitVerdict: Sendable, Equatable {
    case allowed
    /// `reason` is the heuristic that tripped (`volume`, `entropy` or
    /// `similarity`); `retryAfterMs` is when the oldest window entry expires.
    case denied(reason: String, retryAfterMs: Int)

    public var isAllowed: Bool { self == .allowed }
}

/// A window slot held for one intent while it is embedded (`admit`). Fill
/// it with `record(_:vector:)`, or give it back with `release(_:)` when
/// embedding fails.
public struct RateLimitReservation: Sendable, Hashable {
    public let principal: String
    let id: UInt64
    let canonicalLength: Int
}

/// Whether an intent may be embedded; when it may, the slot it holds.
public enum RateLimitAdmission: Sendable, Equatable {
    case admitted(RateLimitReservation)
    case denied(reason: String, retryAfterMs: Int)
}

/// The principal used when a caller does not identify itself.
public let defaultPrincipal = "default"

/// Prevents "Vector Flooding" DoS attacks on the embedder.
///
/// Opt-in: a runtime has one only when `RuntimeOptions.rateLimiter` is set.
/// State is kept per principal (the caller identity passed to resolve and
/// dispatch, e.g. an MCP session; callers that pass none share
/// `defaultPrincipal`), so one client cannot exhaust another's budget. A
/// throttled intent resolves to outcome `throttled` with a retry-after;
/// nothing is thrown. Only novel intents count: a cached resolution or a
/// pinned phrase is never embedded and never consulted here.
///
/// Heuristics, per principal, over a sliding window of recent intent
/// vectors: volume (novel intents), entropy (long canonical forms) and
/// cross-similarity (random noise has low average pairwise similarity).
///
/// Admission is atomic: `admit` checks and takes a window slot in one step,
/// so concurrent novel intents from one principal can't all pass the check
/// before any of them is counted. `evaluate`/`check` only look.
public actor SemanticRateLimiter {
    private struct WindowEntry {
        let timestamp: Date
        /// nil while the intent is still being embedded (a reserved slot)
        var vector: [Float]?
        let canonicalLength: Int
        var reservation: UInt64? = nil
    }

    private struct PrincipalWindow {
        var entries: [WindowEntry] = []
        var pairwiseSimilaritySum: Float = 0
        var pairwiseCount: Int = 0
        var evictionsSinceRecompute: Int = 0
    }

    private let options: SemanticRateLimiterOptions
    private var windows: [String: PrincipalWindow] = [:]
    private let recomputeInterval: Int = 100
    private var lastReservation: UInt64 = 0

    public init(options: SemanticRateLimiterOptions = .init()) {
        self.options = options
    }

    /// Check and reserve in one step: when the intent may be embedded, it
    /// takes a slot in `principal`'s window at once (counted by every
    /// heuristic but similarity until its vector is recorded). Call before
    /// embedding; then `record(_:vector:)` the vector, or `release(_:)` the
    /// slot if embedding failed.
    public func admit(_ canonical: String, principal: String = defaultPrincipal) -> RateLimitAdmission {
        if case .denied(let reason, let retryAfterMs) = evaluate(canonical, principal: principal) {
            return .denied(reason: reason, retryAfterMs: retryAfterMs)
        }
        lastReservation += 1
        var window = self.window(principal, create: true)!
        window.entries.append(WindowEntry(timestamp: Date(), vector: nil, canonicalLength: canonical.count, reservation: lastReservation))
        windows[principal] = window
        return .admitted(RateLimitReservation(principal: principal, id: lastReservation, canonicalLength: canonical.count))
    }

    /// Fill a reserved slot with the intent's vector. A slot that expired
    /// while the intent was embedded is recorded as a new entry.
    public func record(_ reservation: RateLimitReservation, vector: [Float]) {
        var window = self.window(reservation.principal, create: true)!
        for existing in window.entries {
            if let similarity = Self.similarity(existing.vector, vector) {
                window.pairwiseSimilaritySum += similarity
                window.pairwiseCount += 1
            }
        }
        if let index = window.entries.firstIndex(where: { $0.reservation == reservation.id }) {
            window.entries[index].vector = vector
            window.entries[index].reservation = nil
        } else {
            window.entries.append(WindowEntry(timestamp: Date(), vector: vector, canonicalLength: reservation.canonicalLength))
        }
        windows[reservation.principal] = window
    }

    /// Give back a reserved slot (the intent was not embedded).
    public func release(_ reservation: RateLimitReservation) {
        guard var window = windows[reservation.principal] else { return }
        window.entries.removeAll { $0.reservation == reservation.id }
        windows[reservation.principal] = window.entries.isEmpty ? nil : window
    }

    /// Whether a new intent from `principal` may be embedded, and if not,
    /// why and for how long. Only looks: it reserves nothing (see `admit`).
    public func evaluate(_ canonical: String, principal: String = defaultPrincipal) -> RateLimitVerdict {
        guard let window = window(principal, create: false) else { return .allowed }
        let entries = window.entries
        func deny(_ reason: String) -> RateLimitVerdict {
            let oldest = entries.first?.timestamp ?? Date()
            let retry = oldest.timeIntervalSinceNow * 1000 + Double(options.windowMs)
            return .denied(reason: reason, retryAfterMs: max(0, Int(retry.rounded(.up))))
        }

        // Volume cap -- too many novel intents from this principal
        if entries.count >= options.maxNovelIntents { return deny("volume") }

        if entries.count >= options.minSamplesForSimilarity {
            // Entropy -- too many recent intents look like gibberish
            let highEntropyCount = entries.filter { $0.canonicalLength > options.maxCanonicalLength }.count
            if Double(highEntropyCount) / Double(entries.count) >= options.entropyFraction { return deny("entropy") }
            // Similarity -- recent intents are incoherent noise
            if !similarityHealthy(window) { return deny("similarity") }
        }
        return .allowed
    }

    /// Pre-embedding check. Returns true if allowed, false if throttled.
    public func check(_ canonical: String, principal: String = defaultPrincipal) -> Bool {
        evaluate(canonical, principal: principal).isAllowed
    }

    /// Post-embedding record. Stores the vector in the principal's window.
    public func record(_ canonical: String, _ vector: [Float], principal: String = defaultPrincipal) {
        var window = self.window(principal, create: true)!
        for existing in window.entries {
            if let similarity = Self.similarity(existing.vector, vector) {
                window.pairwiseSimilaritySum += similarity
                window.pairwiseCount += 1
            }
        }
        window.entries.append(WindowEntry(timestamp: Date(), vector: vector, canonicalLength: canonical.count))
        windows[principal] = window
    }

    /// Whether the principal's recent traffic is coherent enough. True until
    /// there are `minSamplesForSimilarity` samples.
    public func checkSimilarity(principal: String = defaultPrincipal) -> Bool {
        guard let window = window(principal, create: false),
              window.entries.count >= options.minSamplesForSimilarity else { return true }
        return similarityHealthy(window)
    }

    /// Current flooding metrics for one principal.
    public func getMetrics(principal: String = defaultPrincipal) -> FloodingMetrics {
        let window = self.window(principal, create: false)
        let entries = window?.entries ?? []
        let avgSimilarity: Float = (window?.pairwiseCount ?? 0) > 0
            ? window!.pairwiseSimilaritySum / Float(window!.pairwiseCount)
            : 1.0
        let highEntropyCount = entries.filter { $0.canonicalLength > options.maxCanonicalLength }.count
        let now = Date()
        let oldestTimestamp = entries.first?.timestamp ?? now
        let windowResetsIn = max(
            0,
            Int((oldestTimestamp.timeIntervalSince1970 + Double(options.windowMs) / 1000.0 - now.timeIntervalSince1970) * 1000)
        )
        return FloodingMetrics(
            novelCount: entries.count,
            averageSimilarity: avgSimilarity,
            highEntropyFraction: entries.isEmpty ? 0 : Double(highEntropyCount) / Double(entries.count),
            throttled: !evaluate("", principal: principal).isAllowed,
            windowResetsIn: windowResetsIn
        )
    }

    /// Principals with entries in the current window.
    public func principals() -> [String] {
        for principal in Array(windows.keys) { _ = window(principal, create: false) }
        return Array(windows.keys)
    }

    /// Clear one principal's state, or everyone's.
    public func reset(principal: String? = nil) {
        if let principal { windows.removeValue(forKey: principal) } else { windows.removeAll() }
    }

    /// Cosine similarity of two recorded vectors of the same length.
    private static func similarity(_ a: [Float]?, _ b: [Float]?) -> Float? {
        guard let a, let b, a.count == b.count else { return nil }
        return cosineSimilarity(a, b)
    }

    private func similarityHealthy(_ window: PrincipalWindow) -> Bool {
        let avgSimilarity: Float = window.pairwiseCount > 0
            ? window.pairwiseSimilaritySum / Float(window.pairwiseCount)
            : 1.0
        return avgSimilarity >= options.similarityFloor
    }

    /// A principal's window with stale entries evicted (created on demand).
    private func window(_ principal: String, create: Bool) -> PrincipalWindow? {
        if var window = windows[principal] {
            evictStale(&window)
            if window.entries.isEmpty && !create {
                windows.removeValue(forKey: principal)
                return nil
            }
            windows[principal] = window
            return window
        }
        guard create else { return nil }
        let window = PrincipalWindow()
        windows[principal] = window
        return window
    }

    /// Evict entries older than the sliding window.
    private func evictStale(_ window: inout PrincipalWindow) {
        let cutoff = Date().addingTimeInterval(-Double(options.windowMs) / 1000.0)
        var evictedAny = false
        while let first = window.entries.first, first.timestamp < cutoff {
            let removed = window.entries.removeFirst()
            evictedAny = true
            for remaining in window.entries {
                if let similarity = Self.similarity(removed.vector, remaining.vector) {
                    window.pairwiseSimilaritySum -= similarity
                    window.pairwiseCount -= 1
                }
            }
            window.evictionsSinceRecompute += 1
        }
        // Periodically recompute from scratch to correct floating-point drift
        if evictedAny && window.evictionsSinceRecompute >= recomputeInterval {
            window.pairwiseSimilaritySum = 0
            window.pairwiseCount = 0
            for i in 0..<window.entries.count {
                for j in (i + 1)..<window.entries.count {
                    if let similarity = Self.similarity(window.entries[i].vector, window.entries[j].vector) {
                        window.pairwiseSimilaritySum += similarity
                        window.pairwiseCount += 1
                    }
                }
            }
            window.evictionsSinceRecompute = 0
        }
    }
}
