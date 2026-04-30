import SmallChatCore

// MARK: - LLMClient

/// Pluggable LLM verification client.
///
/// Used by Phase 2 verification, decomposition, and refinement when an
/// optional LLM-backed reasoning step is available. Implementations should
/// degrade gracefully when offline or unconfigured -- prefer returning
/// `.unavailable` over throwing.
public protocol LLMClient: Sendable {
    /// Verify whether `intent` is a reasonable match for `toolName` given
    /// the tool description. Returns a confidence in [0, 1] or
    /// `.unavailable` when the client cannot answer.
    func verifyMatch(
        intent: String,
        toolName: String,
        toolDescription: String
    ) async -> LLMVerificationResult

    /// Decompose a complex intent into ordered sub-intents.
    func decompose(intent: String) async -> LLMDecompositionResult

    /// Suggest clarifying questions for an unmatched intent.
    func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String]
}

// MARK: - Result types

public enum LLMVerificationResult: Sendable, Equatable {
    case verified(confidence: Double)
    case rejected(reason: String)
    case unavailable
}

public enum LLMDecompositionResult: Sendable, Equatable {
    case decomposed(subIntents: [String])
    case atomic
    case unavailable
}

// MARK: - NoOpLLMClient

/// Default client that always returns `.unavailable`. Lets the dispatch
/// pipeline execute end-to-end without any LLM configured.
public struct NoOpLLMClient: LLMClient {
    public init() {}

    public func verifyMatch(
        intent: String,
        toolName: String,
        toolDescription: String
    ) async -> LLMVerificationResult {
        .unavailable
    }

    public func decompose(intent: String) async -> LLMDecompositionResult {
        .unavailable
    }

    public func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String] {
        []
    }
}
