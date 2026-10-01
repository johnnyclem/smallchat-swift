import Testing
@testable import SmallChatCore

@Suite("DispatchTier")
struct DispatchTierTests {

    @Test("Default thresholds are the suite's: EXACT .95, HIGH .85, MEDIUM .75, LOW .60")
    func tierClassification() {
        let config = DispatchConfig()
        #expect(config.tier(for: 0.99) == .exact)
        #expect(config.tier(for: 0.95) == .exact)
        #expect(config.tier(for: 0.90) == .high)
        #expect(config.tier(for: 0.75) == .medium)
        #expect(config.tier(for: 0.72) == .low)
        #expect(config.tier(for: 0.60) == .low)
        #expect(config.tier(for: 0.40) == .none)
    }

    @Test("Scores are quantized before they are compared with a threshold")
    func quantizedTiers() {
        #expect(DispatchConfig().tier(for: 0.94996) == .exact)
        #expect(DispatchConfig().tier(for: 0.94994) == .high)
    }

    @Test("A close runner-up does not change the tier (no ambiguity downgrade)")
    func noAmbiguityDowngrade() {
        // 0.6 downgraded 0.90 to MEDIUM when the runner-up was within 0.05;
        // @smallchat/core has no such rule.
        #expect(DispatchConfig().tier(for: 0.90) == .high)
    }

    @Test("Policy guards default to the suite's")
    func policyDefaults() {
        let config = DispatchConfig()
        #expect(config.strict == false)
        #expect(config.requireLLMForSubHighDispatch == true)
        #expect(config.treatUnannotatedAsDestructive == false)
        #expect(config.maxDecompositionDepth == 2)
        #expect(config.maxSubDispatches == 16)
        #expect(DispatchConfig(strict: true).strict == true)
    }

    @Test("miniLM preset lifts MiniLM-typical paraphrase scores out of LOW")
    func miniLMPresetClassifiesTypicalScoresHigher() {
        let config = DispatchConfig.miniLM
        // Observed MiniLM cosine scores for a *correct* paraphrase match
        // run 0.60-0.74 (see smallchat-swift#36).
        #expect(config.tier(for: 0.75) == .high)
        #expect(config.tier(for: 0.74) == .medium)
        #expect(config.tier(for: 0.61) == .medium)
        #expect(DispatchConfig().tier(for: 0.61) == .low)
    }

    @Test("miniLM preset thresholds are strictly looser than the plain default")
    func miniLMPresetIsLooserThanDefault() {
        let plain = DispatchConfig()
        let miniLM = DispatchConfig.miniLM
        #expect(miniLM.exactThreshold < plain.exactThreshold)
        #expect(miniLM.highThreshold < plain.highThreshold)
        #expect(miniLM.mediumThreshold < plain.mediumThreshold)
        #expect(miniLM.lowThreshold < plain.lowThreshold)
    }

    @Test("ResolutionProof records steps, totals timings outside the digest")
    func proofRecording() {
        var proof = ResolutionProof(intent: "x")
        proof.addStep(.vectorSearch, "searched", elapsedMs: 1.5)
        proof.addStep(.policy, "allowed", elapsedMs: 2)
        proof.finalize()
        #expect(proof.steps.count == 2)
        #expect(proof.timings.totalMs == 3.5)

        var slower = proof
        slower.timings = ProofTimings(totalMs: 99, stepsMs: [50, 49])
        #expect(slower.computeDigest() == proof.proofDigest)
        #expect(proof.proofDigest.count == 64)
    }

    @Test("ToolRefinement carries the canonical MCP result-type discriminator")
    func refinementMCPType() {
        #expect(ToolRefinement.mcpResultType == "tool_refinement_needed")

        let refinement = ToolRefinement(
            originalIntent: "x",
            reason: "y",
            clarifyingQuestions: ["q1"],
            nearMatches: [
                ToolRefinement.NearMatch(
                    toolName: "loom_find_importers",
                    providerId: "loom",
                    canonicalSelector: "loom.loom_find_importers",
                    confidence: 0.62
                )
            ],
            proof: ResolutionProof()
        )
        #expect(refinement.nearMatches.first?.confidence == 0.62)
        #expect(refinement.nearMatches.first?.toolId == "loom/loom_find_importers")
        #expect(refinement.proof.tier == .none)
    }
}
