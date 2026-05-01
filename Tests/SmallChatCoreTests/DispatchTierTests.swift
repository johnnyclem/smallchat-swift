import Testing
@testable import SmallChatCore

@Suite("DispatchTier")
struct DispatchTierTests {

    @Test("Default config classifies confidence into tiers")
    func tierClassification() {
        let config = DispatchConfig()
        #expect(config.tier(for: 0.99) == .exact)
        #expect(config.tier(for: 0.90) == .high)
        #expect(config.tier(for: 0.75) == .medium)
        #expect(config.tier(for: 0.60) == .low)
        #expect(config.tier(for: 0.40) == .none)
    }

    @Test("Ambiguous runner-up downgrades the tier by one step")
    func ambiguityDowngrade() {
        let config = DispatchConfig(ambiguityGap: 0.05)
        // Top is HIGH (0.90), runner-up only 0.02 behind -> downgrades to MEDIUM
        #expect(config.tier(for: 0.90, runnerUp: 0.88) == .medium)
        // Same top, runner-up >= ambiguityGap behind -> stays HIGH
        #expect(config.tier(for: 0.90, runnerUp: 0.80) == .high)
    }

    @Test("Default vector-search threshold is 0.60 (was 0.75 in 0.3.0)")
    func defaultThreshold() {
        #expect(DispatchConfig().vectorSearchThreshold == 0.60)
    }

    @Test("Strict mode is opt-in")
    func strictDefault() {
        #expect(DispatchConfig().strict == false)
        #expect(DispatchConfig(strict: true).strict == true)
    }

    @Test("ResolutionProof records steps and totals microseconds")
    func proofRecording() {
        var proof = ResolutionProof()
        proof.record(ResolutionStep(stage: "a", detail: "x", outcome: .hit, elapsedMicroseconds: 10))
        proof.record(ResolutionStep(stage: "b", detail: "y", outcome: .miss, elapsedMicroseconds: 25))
        #expect(proof.steps.count == 2)
        #expect(proof.totalElapsedMicroseconds == 35)
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
            proof: ResolutionProof(finalTier: .none)
        )
        #expect(refinement.nearMatches.first?.confidence == 0.62)
        #expect(refinement.proof.finalTier == .none)
    }
}
