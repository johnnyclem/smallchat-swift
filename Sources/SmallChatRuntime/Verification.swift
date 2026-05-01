import Foundation
import SmallChatCore

// MARK: - VerificationResult

public struct VerificationResult: Sendable, Equatable {
    public let passed: Bool
    public let reason: String
    public let strategy: Strategy

    public enum Strategy: String, Sendable, Equatable {
        case schema
        case keywordOverlap
        case llm
    }

    public init(passed: Bool, reason: String, strategy: Strategy) {
        self.passed = passed
        self.reason = reason
        self.strategy = strategy
    }
}

// MARK: - Pre-flight verification

/// Pre-flight `respondsToSelector:` for a candidate tool.
///
/// Three progressive strategies, applied in order:
///   1. Schema validation -- do supplied args satisfy the tool's schema?
///   2. Keyword overlap   -- does the intent share salient terms with the
///      tool's name + description?
///   3. LLM verification  -- (optional) ask the configured `LLMClient`.
///
/// Verification is intentionally fail-fast: the first failing strategy
/// returns. The first passing strategy short-circuits when the next
/// strategies are unavailable (e.g. no args supplied, no LLM configured).
public func verifyCandidate(
    intent: String,
    toolName: String,
    toolDescription: String,
    arguments: [ArgumentSpec],
    suppliedArgs: [String: any Sendable]?,
    llm: any LLMClient = NoOpLLMClient()
) async -> VerificationResult {

    // Strategy 1: schema validation when args are supplied.
    if let args = suppliedArgs, !args.isEmpty {
        let missing = arguments
            .filter(\.required)
            .map(\.name)
            .filter { args[$0] == nil }
        if !missing.isEmpty {
            return VerificationResult(
                passed: false,
                reason: "missing required arguments: \(missing.joined(separator: ", "))",
                strategy: .schema
            )
        }
    }

    // Strategy 2: keyword overlap (cheap, deterministic).
    let overlap = keywordOverlap(intent: intent, toolName: toolName, toolDescription: toolDescription)
    if overlap < 0.10 {
        return VerificationResult(
            passed: false,
            reason: String(format: "low keyword overlap (%.2f) between intent and tool", overlap),
            strategy: .keywordOverlap
        )
    }

    // Strategy 3: optional LLM verification.
    let llmResult = await llm.verifyMatch(
        intent: intent,
        toolName: toolName,
        toolDescription: toolDescription
    )
    switch llmResult {
    case .verified(let confidence) where confidence >= 0.5:
        return VerificationResult(passed: true, reason: "llm-verified", strategy: .llm)
    case .verified(let confidence):
        return VerificationResult(
            passed: false,
            reason: String(format: "llm low confidence (%.2f)", confidence),
            strategy: .llm
        )
    case .rejected(let reason):
        return VerificationResult(passed: false, reason: "llm rejected: \(reason)", strategy: .llm)
    case .unavailable:
        // No LLM configured: trust the keyword-overlap result.
        return VerificationResult(passed: true, reason: "keyword-overlap ok", strategy: .keywordOverlap)
    }
}

// MARK: - Helpers

/// Jaccard-like overlap of meaningful tokens (lowercased, length >= 3,
/// stop-words removed) between the intent and the tool's name+description.
public func keywordOverlap(intent: String, toolName: String, toolDescription: String) -> Double {
    let intentTokens = tokenize(intent)
    let toolTokens = tokenize("\(toolName) \(toolDescription)")
    if intentTokens.isEmpty || toolTokens.isEmpty { return 0.0 }
    let overlap = intentTokens.intersection(toolTokens).count
    let union = intentTokens.union(toolTokens).count
    return union == 0 ? 0.0 : Double(overlap) / Double(union)
}

private let stopWords: Set<String> = [
    "the", "and", "for", "from", "with", "into", "this", "that", "what",
    "where", "when", "which", "have", "has", "had", "are", "was", "were",
    "you", "your", "our", "their", "how", "why", "all", "any", "some",
    "show", "find", "get", "give", "tell", "make"
]

private func tokenize(_ text: String) -> Set<String> {
    var tokens = Set<String>()
    var current = ""
    for ch in text.lowercased() {
        if ch.isLetter || ch.isNumber || ch == "_" {
            current.append(ch)
        } else if !current.isEmpty {
            if current.count >= 3, !stopWords.contains(current) {
                tokens.insert(current)
            }
            current = ""
        }
    }
    if current.count >= 3, !stopWords.contains(current) {
        tokens.insert(current)
    }
    return tokens
}
