import SmallChatCore

// MARK: - LLMClient

/// Pluggable LLM verification client.
///
/// Used by verification, decomposition, and refinement when an optional
/// LLM-backed reasoning step is available. Implementations should degrade
/// gracefully when offline or unconfigured -- prefer returning
/// `.unavailable` over throwing.
///
/// Below HIGH confidence the dispatch policy runs a tool only when this
/// client's `verifyMatch` approves it (`.verified` with confidence >= 0.5),
/// unless `DispatchConfig.requireLLMForSubHighDispatch` is off. An answer of
/// `.unavailable` approves nothing.
public protocol LLMClient: Sendable {
    /// Whether this client can verify matches at all (the policy then asks
    /// it below HIGH). `NoOpLLMClient` returns false; the default is true.
    var providesVerification: Bool { get }

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

extension LLMClient {
    public var providesVerification: Bool { true }
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

    public var providesVerification: Bool { false }

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
