import SmallChatCore

// MARK: - Decomposition

/// Outcome of decomposing a low-confidence intent.
public struct DecompositionResult: Sendable, Equatable {
    public let subIntents: [String]
    public let strategy: Strategy

    public enum Strategy: String, Sendable, Equatable {
        case rule
        case llm
        case noop
    }

    public init(subIntents: [String], strategy: Strategy) {
        self.subIntents = subIntents
        self.strategy = strategy
    }

    public var didDecompose: Bool { subIntents.count > 1 }
}

/// Split a LOW-tier intent into ordered sub-intents.
///
/// First applies a deterministic rule-based split on natural conjunctions
/// ("then", "and then", "after that", "also", "; "). Falls back to the
/// configured `LLMClient` when no conjunction is found and the client is
/// available. Returns `.noop` with a single-element array when the intent
/// is already atomic.
public func decomposeIntent(
    _ intent: String,
    llm: any LLMClient = NoOpLLMClient()
) async -> DecompositionResult {

    // Rule-based split on conjunctions.
    if let parts = ruleBasedSplit(intent) {
        return DecompositionResult(subIntents: parts, strategy: .rule)
    }

    // LLM-assisted fallback.
    let llmResult = await llm.decompose(intent: intent)
    switch llmResult {
    case .decomposed(let subIntents) where subIntents.count > 1:
        return DecompositionResult(subIntents: subIntents, strategy: .llm)
    case .decomposed, .atomic, .unavailable:
        return DecompositionResult(subIntents: [intent], strategy: .noop)
    }
}

private let conjunctions: [String] = [
    " then ", " and then ", " after that ", " followed by ",
    "; ", " also "
]

private func ruleBasedSplit(_ intent: String) -> [String]? {
    let normalized = intent.lowercased()
    for conj in conjunctions where normalized.contains(conj) {
        // Case-insensitive split preserving original casing in segments.
        let parts = caseInsensitiveSplit(intent, on: conj)
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.count > 1 { return cleaned }
    }
    return nil
}

private func caseInsensitiveSplit(_ s: String, on separator: String) -> [String] {
    var result: [String] = []
    var remainder = s
    let lowerSep = separator.lowercased()
    while let range = remainder.range(of: lowerSep, options: .caseInsensitive) {
        result.append(String(remainder[..<range.lowerBound]))
        remainder = String(remainder[range.upperBound...])
    }
    result.append(remainder)
    return result
}
