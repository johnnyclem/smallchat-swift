import Foundation
#if canImport(os)
import os
#endif

public enum IntentPinPolicy: String, Sendable {
    case exact
    case elevated
}

public struct IntentPin: Sendable {
    public let canonical: String
    public let policy: IntentPinPolicy
    public let threshold: Double?
    public let aliases: [String]?

    public init(
        canonical: String,
        policy: IntentPinPolicy,
        threshold: Double? = nil,
        aliases: [String]? = nil
    ) {
        self.canonical = canonical
        self.policy = policy
        self.threshold = threshold
        self.aliases = aliases
    }
}

public struct IntentPinMatch: Sendable {
    public let canonical: String
    public let verdict: Verdict
    public let policy: IntentPinPolicy
    public let similarity: Double?
    public let requiredThreshold: Double?

    public enum Verdict: String, Sendable {
        case accept
        case reject
    }

    public init(
        canonical: String,
        verdict: Verdict,
        policy: IntentPinPolicy,
        similarity: Double? = nil,
        requiredThreshold: Double? = nil
    ) {
        self.canonical = canonical
        self.verdict = verdict
        self.policy = policy
        self.similarity = similarity
        self.requiredThreshold = requiredThreshold
    }
}

/// Default elevated-policy threshold
private let defaultElevatedThreshold: Double = 0.98

/// Guards sensitive selectors against semantic collision attacks.
///
/// - `.exact`: only a pinned phrase dispatches to the pinned tool -- the
///   pin's canonical or one of its aliases, compared as whole phrases after
///   `normalizePinPhrase` (so "do not transfer funds" never matches the
///   alias "transfer funds"). Cosine similarity is never enough.
/// - `.elevated`: requires a cosine similarity, computed from the intent's
///   own embedding, at or above the pin's threshold (default 0.98).
///
/// Lock-based for synchronous reads on the dispatch hot path.
public final class IntentPinRegistry: Sendable {
    private let lock: PlatformLock<State>

    struct State: Sendable {
        var pins: [String: IntentPin] = [:]
        /// Normalized pinned phrase (canonical or alias) -> pin canonical
        var phraseIndex: [String: String] = [:]
    }

    public init() {
        self.lock = PlatformLock(initialState: State())
    }

    /// Pin a selector with a given policy (replacing an earlier pin on it).
    public func pin(_ entry: IntentPin) {
        lock.withLock { state in
            Self.remove(entry.canonical, from: &state)
            state.pins[entry.canonical] = entry
            for phrase in [entry.canonical] + (entry.aliases ?? []) {
                state.phraseIndex[normalizePinPhrase(phrase)] = entry.canonical
            }
        }
    }

    /// Remove a pin.
    public func unpin(_ canonical: String) {
        lock.withLock { state in Self.remove(canonical, from: &state) }
    }

    private static func remove(_ canonical: String, from state: inout State) {
        state.phraseIndex = state.phraseIndex.filter { $0.value != canonical }
        state.pins.removeValue(forKey: canonical)
    }

    /// Check if a selector canonical name is pinned.
    public func isPinned(_ canonical: String) -> Bool {
        lock.withLock { state in
            state.pins[canonical] != nil
        }
    }

    /// Get the pin entry for a canonical name.
    public func getPin(_ canonical: String) -> IntentPin? {
        lock.withLock { state in
            state.pins[canonical]
        }
    }

    /// Number of pinned selectors.
    public var size: Int {
        lock.withLock { state in
            state.pins.count
        }
    }

    /// All pinned canonicals, sorted.
    public func pinnedCanonicals() -> [String] {
        lock.withLock { state in
            state.pins.keys.sorted()
        }
    }

    /// Whether `intent` is one of the pinned phrases of the pin on `canonical`.
    public func matchesPinnedPhrase(_ canonical: String, intent: String) -> Bool {
        lock.withLock { state in
            state.phraseIndex[normalizePinPhrase(intent)] == canonical
        }
    }

    /// Is the intent, as a whole phrase, one of the pinned phrases (a pin's
    /// canonical or alias, compared with `normalizePinPhrase`)? Returns the
    /// accepted pin, or nil when the intent is not a pinned phrase.
    ///
    /// Pass the raw intent text. 0.x compared `canonicalize`d forms, which
    /// drop words such as "not".
    public func checkExact(_ intent: String) -> IntentPinMatch? {
        lock.withLock { state in
            guard let target = state.phraseIndex[normalizePinPhrase(intent)],
                  let pin = state.pins[target] else { return nil }
            return IntentPinMatch(canonical: pin.canonical, verdict: .accept, policy: pin.policy)
        }
    }

    /// Whether a similarity match to a pinned selector is accepted under the
    /// pin's policy. `similarity` must come from the intent's own embedding;
    /// `intent` is the raw intent text. nil when the selector is not pinned.
    public func checkSimilarity(
        candidateCanonical: String,
        similarity: Double,
        intent: String
    ) -> IntentPinMatch? {
        lock.withLock { state in
            guard let pin = state.pins[candidateCanonical] else { return nil }

            switch pin.policy {
            case .exact:
                // Only a pinned phrase is accepted, whatever the score.
                let isPhrase = state.phraseIndex[normalizePinPhrase(intent)] == candidateCanonical
                return IntentPinMatch(
                    canonical: pin.canonical,
                    verdict: isPhrase ? .accept : .reject,
                    policy: .exact
                )
            case .elevated:
                let threshold = pin.threshold ?? defaultElevatedThreshold
                return IntentPinMatch(
                    canonical: pin.canonical,
                    verdict: similarity >= threshold ? .accept : .reject,
                    policy: .elevated,
                    similarity: similarity,
                    requiredThreshold: threshold
                )
            }
        }
    }
}
