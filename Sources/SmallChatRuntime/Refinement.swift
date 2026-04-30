import SmallChatCore

// MARK: - Refinement

/// Build a `ToolRefinement` payload for a NONE-tier dispatch.
///
/// The payload is the body of the `tool_refinement_needed` MCP result
/// returned to the caller. It carries the original intent, an explanation,
/// near-miss candidates with confidences, optional clarifying questions
/// from the LLM, and the resolution proof for replay/debugging.
public func makeRefinement(
    originalIntent: String,
    candidates: [ToolCandidate],
    proof: ResolutionProof,
    llm: any LLMClient = NoOpLLMClient()
) async -> ToolRefinement {

    let nearMatches: [ToolRefinement.NearMatch] = candidates
        .sorted { $0.confidence > $1.confidence }
        .prefix(5)
        .map { c in
            ToolRefinement.NearMatch(
                toolName: c.imp.toolName,
                providerId: c.imp.providerId,
                canonicalSelector: c.selector.canonical,
                confidence: c.confidence
            )
        }

    let reason: String
    if candidates.isEmpty {
        reason = "No candidates above the minimum vector-search threshold."
    } else if let best = candidates.max(by: { $0.confidence < $1.confidence }) {
        reason = String(
            format: "Best candidate \"%@\" only scored %.2f -- below the LOW threshold.",
            best.imp.toolName, best.confidence
        )
    } else {
        reason = "Refinement required."
    }

    let questions = await llm.clarifyingQuestions(
        intent: originalIntent,
        nearMatches: nearMatches.map(\.toolName)
    )

    return ToolRefinement(
        originalIntent: originalIntent,
        reason: reason,
        clarifyingQuestions: questions,
        nearMatches: nearMatches,
        proof: proof
    )
}
