import Foundation
import SmallChatCore

// MARK: - TieredDispatchResult

/// Outcome of a tiered dispatch.
///
/// `.dispatched` carries the executed `ToolResult` plus the tier and proof
/// trace. `.refinement` carries a `ToolRefinement` payload to be returned
/// to the caller as a `tool_refinement_needed` MCP result. `.decomposed`
/// carries a sequence of sub-intents that the caller is expected to
/// re-dispatch in order (the runtime does not auto-execute decompositions
/// because each sub-intent may have its own argument set).
public enum TieredDispatchResult: Sendable {
    case dispatched(result: ToolResult, tier: DispatchTier, proof: ResolutionProof)
    case decomposed(subIntents: [String], proof: ResolutionProof)
    case refinement(ToolRefinement)
    case strictAmbiguityError(reason: String, proof: ResolutionProof)
}

// MARK: - TieredDispatchError

public struct StrictAmbiguityError: Error, Sendable {
    public let reason: String
    public let proof: ResolutionProof
}

// MARK: - tieredDispatch

/// 0.5.0 dispatch entry point: classifies confidence into a tier and
/// applies tier-specific behavior on top of the existing resolution
/// pipeline.
///
/// Tier behavior:
///   - `.exact` / `.high`  -- execute immediately
///   - `.medium`           -- run pre-flight verification; on failure,
///                            either dispatch anyway or downgrade to LOW
///                            depending on `config.strict`
///   - `.low`              -- decompose; if decomposition produces > 1
///                            sub-intents, return them; otherwise refine
///   - `.none`             -- return a `ToolRefinement`
///
/// The legacy `toolkitDispatch` entry point remains available for callers
/// that don't need tier classification.
public func tieredDispatch(
    context: DispatchContext,
    intent: String,
    args: [String: any Sendable]? = nil,
    llm: any LLMClient = NoOpLLMClient(),
    observer: DispatchObserver? = nil
) async throws -> TieredDispatchResult {

    let config = context.dispatchConfig
    let timer = ProofTimer()
    var proof = ResolutionProof()

    // Sanitize intent. Keep this in the proof so callers can see the
    // canonical form their intent was reduced to.
    let sanitized: String
    do {
        sanitized = try validateIntent(intent)
        proof.record(ResolutionStep(
            stage: "validate-intent",
            detail: "ok",
            outcome: .hit,
            elapsedMicroseconds: timer.microsecondsSinceStart()
        ))
    } catch {
        proof.record(ResolutionStep(
            stage: "validate-intent",
            detail: String(describing: error),
            outcome: .error,
            elapsedMicroseconds: timer.microsecondsSinceStart()
        ))
        throw error
    }

    // Run the existing resolver to get IMP + candidates.
    let resolveStart = ProofTimer()
    let outcome: ResolutionOutcome
    do {
        outcome = try await resolveToolIMP(context: context, intent: sanitized, args: args)
    } catch {
        proof.record(ResolutionStep(
            stage: "resolve",
            detail: String(describing: error),
            outcome: .error,
            elapsedMicroseconds: resolveStart.microsecondsSinceStart()
        ))
        throw error
    }

    proof.record(ResolutionStep(
        stage: "resolve",
        detail: "completed",
        outcome: .hit,
        elapsedMicroseconds: resolveStart.microsecondsSinceStart()
    ))

    switch outcome {

    case .forwarded(let result):
        // Forwarded results bypass the tier system; emit at HIGH so the
        // caller treats them like a normal dispatch.
        proof.finalTier = .high
        await observer?.record(.accepted(toolName: "forwarded", tier: .high, confidence: 0.7))
        return .dispatched(result: result, tier: .high, proof: proof)

    case .resolved(let imp, let confidence, let selector, let candidates):
        let runnerUp = candidates.dropFirst().first?.confidence
        let tier = config.tier(for: confidence, runnerUp: runnerUp)
        proof.finalTier = tier

        switch tier {
        case .exact, .high:
            let result = try await executeWithArgs(imp, args: args ?? [:])
            await observer?.record(.accepted(
                toolName: "\(imp.providerId).\(imp.toolName)",
                tier: tier,
                confidence: confidence
            ))
            return .dispatched(result: result, tier: tier, proof: proof)

        case .medium:
            if config.enableVerification {
                let verifyStart = ProofTimer()
                let (description, arguments) = await loadDescriptor(for: imp)
                let verification = await verifyCandidate(
                    intent: sanitized,
                    toolName: imp.toolName,
                    toolDescription: description,
                    arguments: arguments,
                    suppliedArgs: args,
                    llm: llm
                )
                proof.record(ResolutionStep(
                    stage: "verify",
                    detail: "\(verification.strategy.rawValue): \(verification.reason)",
                    outcome: verification.passed ? .hit : .miss,
                    elapsedMicroseconds: verifyStart.microsecondsSinceStart()
                ))
                if !verification.passed {
                    if config.strict {
                        return .strictAmbiguityError(
                            reason: "MEDIUM-tier verification failed: \(verification.reason)",
                            proof: proof
                        )
                    }
                    // Downgrade to LOW: try decomposition / refinement.
                    return await handleLowOrNone(
                        intent: sanitized,
                        candidates: candidates,
                        proof: proof,
                        config: config,
                        llm: llm,
                        observer: observer,
                        forcedTier: .low
                    )
                }
            }
            let result = try await executeWithArgs(imp, args: args ?? [:])
            await observer?.record(.accepted(
                toolName: "\(imp.providerId).\(imp.toolName)",
                tier: tier,
                confidence: confidence
            ))
            _ = selector
            return .dispatched(result: result, tier: .medium, proof: proof)

        case .low:
            return await handleLowOrNone(
                intent: sanitized,
                candidates: candidates,
                proof: proof,
                config: config,
                llm: llm,
                observer: observer,
                forcedTier: .low
            )

        case .none:
            return await handleLowOrNone(
                intent: sanitized,
                candidates: candidates,
                proof: proof,
                config: config,
                llm: llm,
                observer: observer,
                forcedTier: .none
            )
        }
    }
}

// MARK: - LOW / NONE handling

private func handleLowOrNone(
    intent: String,
    candidates: [ToolCandidate],
    proof: ResolutionProof,
    config: DispatchConfig,
    llm: any LLMClient,
    observer: DispatchObserver?,
    forcedTier: DispatchTier
) async -> TieredDispatchResult {

    var proof = proof
    proof.finalTier = forcedTier

    if config.strict {
        return .strictAmbiguityError(
            reason: "Tier \(forcedTier.rawValue) is not dispatchable under --strict.",
            proof: proof
        )
    }

    // LOW: try decomposition first.
    if forcedTier == .low, config.enableDecomposition {
        let decomposeStart = ProofTimer()
        let decomp = await decomposeIntent(intent, llm: llm)
        proof.record(ResolutionStep(
            stage: "decompose",
            detail: "\(decomp.strategy.rawValue): \(decomp.subIntents.count) sub-intents",
            outcome: decomp.didDecompose ? .hit : .miss,
            elapsedMicroseconds: decomposeStart.microsecondsSinceStart()
        ))
        if decomp.didDecompose {
            await observer?.record(.refined(intent: intent, tier: .low))
            return .decomposed(subIntents: decomp.subIntents, proof: proof)
        }
    }

    // Otherwise emit a refinement.
    if config.enableRefinement {
        let refineStart = ProofTimer()
        let refinement = await makeRefinement(
            originalIntent: intent,
            candidates: candidates,
            proof: proof,
            llm: llm
        )
        var augmented = proof
        augmented.record(ResolutionStep(
            stage: "refine",
            detail: "\(refinement.nearMatches.count) near-matches",
            outcome: .hit,
            elapsedMicroseconds: refineStart.microsecondsSinceStart()
        ))
        await observer?.record(.refined(intent: intent, tier: forcedTier))
        return .refinement(ToolRefinement(
            originalIntent: refinement.originalIntent,
            reason: refinement.reason,
            clarifyingQuestions: refinement.clarifyingQuestions,
            nearMatches: refinement.nearMatches,
            proof: augmented
        ))
    }

    // Refinement disabled and no decomposition: emit a minimal refinement.
    return .refinement(ToolRefinement(
        originalIntent: intent,
        reason: "No confident match and refinement disabled.",
        proof: proof
    ))
}

// MARK: - Tool descriptor lookup

/// Best-effort access to a tool's description + arguments via its IMP.
/// `ToolIMP` exposes name and providerId; richer metadata is fetched
/// lazily through `ToolProxy` when available, falling back to the tool
/// name when the schema cannot be resolved.
private func loadDescriptor(for imp: any ToolIMP) async -> (description: String, arguments: [ArgumentSpec]) {
    if let proxy = imp as? ToolProxy {
        if let schema = try? await proxy.loadSchema() {
            return (schema.description, schema.arguments)
        }
    }
    return (imp.toolName, [])
}
