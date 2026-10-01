import SmallChatCore

// MARK: - Refinement

/// Build a `ToolRefinement` payload: what to ask when resolution does not
/// settle on one tool (needs-disambiguation, or unresolved with near
/// matches). Nothing ran; each near match carries a tool id the caller can
/// run with `dispatchById`.
///
/// Near matches are the first five `candidates`, in the deterministic
/// ranking order (quantized score, then tool id). The configured `LLMClient`
/// may add clarifying questions.
public func makeRefinement(
    originalIntent: String,
    candidates: [ToolCandidate],
    proof: ResolutionProof,
    llm: any LLMClient = NoOpLLMClient(),
    reason: String? = nil
) async -> ToolRefinement {

    let nearMatches: [ToolRefinement.NearMatch] = candidates
        .sorted { rankedBefore(score: $0.confidence, toolId: $0.imp.toolId, score: $1.confidence, toolId: $1.imp.toolId) }
        .prefix(5)
        .map { c in
            ToolRefinement.NearMatch(
                toolName: c.imp.toolName,
                providerId: c.imp.providerId,
                canonicalSelector: c.selector.canonical,
                confidence: quantizeScore(c.confidence)
            )
        }

    let explanation: String
    if let reason {
        explanation = reason
    } else if let best = nearMatches.first {
        explanation = "Best candidate \(best.toolId) only scored \(fixed3(best.confidence)); choose a tool and call it by id."
    } else {
        explanation = "No candidates above the minimum similarity."
    }

    let questions = await llm.clarifyingQuestions(
        intent: originalIntent,
        nearMatches: nearMatches.map(\.toolId)
    )

    return ToolRefinement(
        originalIntent: originalIntent,
        reason: explanation,
        clarifyingQuestions: questions,
        nearMatches: nearMatches,
        proof: proof
    )
}
