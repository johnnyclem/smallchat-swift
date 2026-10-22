import Foundation
import SmallChatCore

// MARK: - Explain (@smallchat/core 1.0 runtime/explain.ts)
//
// Why a resolution came out the way it did, for operators. Adds to the
// resolution's proof, for every candidate: its rank, the tool's MCP
// annotations, whether it counts as destructive or pinned, and the dispatch
// policy's verdict on running it without the caller naming it. The judge is
// reported from the runtime (whether one is configured), from the proof
// (what it decided) and, for an intent explain resolved itself, whether a
// live dispatch would ask it; explaining never calls it. Nothing executes.

/// One row of the candidate table.
public struct ExplainedCandidate: Sendable, Equatable {
    public var candidate: ProofCandidate
    /// 1-based rank among eligible candidates; nil for excluded ones
    public var rank: Int?
    public var chosen: Bool
    public var annotations: ToolAnnotations?
    public var destructive: Bool
    public var pinned: Bool
    /// Policy verdict on running it without the caller choosing; nil when excluded
    public var verdict: PolicyVerdict?

    public var toolId: String { candidate.toolId }
}

/// The shortlist judge as the runtime has it configured (never its credentials).
public struct ExplainedJudge: Sendable, Equatable {
    public var name: String
    public var model: String
    public var margin: Double
    public var maxCandidates: Int
    public var acceptThreshold: Double
    public var timeoutMs: Int
}

/// What a live dispatch would ask the judge (explain never asks it).
public struct JudgeWouldAsk: Sendable, Equatable {
    public var trigger: JudgeTrigger
    public var offered: [String]
}

public struct Explanation: Sendable {
    public var intent: String
    public var outcome: ResolutionOutcome
    public var decision: DecisionCode
    public var tier: DispatchTier
    public var chosen: String?
    public var reason: String?
    public var candidates: [ExplainedCandidate]
    public var thresholds: TierThresholds
    public var guards: ProofGuards
    public var embedder: EmbedderFingerprint?
    public var artifactHash: String?
    /// The runtime's judge, or nil without one
    public var judgeConfigured: ExplainedJudge?
    /// What the judge decided for this resolution, from the proof (nil when not consulted)
    public var judgeConsulted: JudgeRecord?
    /// Set when explain(intent) resolved with a judge configured and none answering:
    /// `.some(nil)` when a live dispatch would not ask it, `.some(x)` when it would.
    public var judgeWouldAsk: JudgeWouldAsk??
    public var steps: [ProofStep]
    public var proofDigest: String
    public var resolution: Resolution
}

extension DispatchContext {
    /// Explain a resolution made by this context.
    func explainResolution(_ resolution: Resolution, wouldAsk: (trigger: JudgeTrigger, offered: [String])?? = nil) async -> Explanation {
        let proof = resolution.proof
        var ownVector: [Float]?
        let embedder = self.embedder
        let intent = resolution.intent
        func ownSimilarity(_ selector: ToolSelector) async throws -> Double {
            if ownVector == nil { ownVector = try await embedder.embed(intent) }
            return quantizeScore(cosineSimilarityDouble(ownVector!, selector.vector))
        }
        let eligible = Set(resolution.candidates.map(\.toolId))
        var rank = 0
        var candidates: [ExplainedCandidate] = []
        for c in proof.candidates {
            let tool = getTool(c.toolId)
            let annotations = tool?.imp.annotations
            let destructive = isDestructive(annotations, treatUnannotatedAsDestructive: dispatchConfig.treatUnannotatedAsDestructive)
            let pinned = isPinnedTool(c.toolId, via: c.selector)
            let isEligible = c.excluded == nil && eligible.contains(c.toolId)
            var verdict: PolicyVerdict?
            if isEligible, let tool {
                let pins = (try? await pinStates(for: c.toolId, intent: intent, via: c.selector, ownSimilarity: ownSimilarity)) ?? []
                let llmApproved = proof.chosen == c.toolId && (proof.decision == .llmVerified || proof.decision == .judgeApproved)
                verdict = evaluateDispatchPolicy(
                    PolicyInput(mode: .intent, toolId: c.toolId, annotations: tool.imp.annotations, source: c.source, score: c.score,
                                similarity: c.similarity, llmApproved: llmApproved, pins: pins),
                    options: policyOptions
                )
            }
            if isEligible { rank += 1 }
            candidates.append(ExplainedCandidate(candidate: c, rank: isEligible ? rank : nil, chosen: proof.chosen == c.toolId,
                                                 annotations: annotations, destructive: destructive, pinned: pinned, verdict: verdict))
        }
        var configured: ExplainedJudge?
        if let judge, let settings = judgeSettings {
            configured = ExplainedJudge(name: judge.name, model: judge.model, margin: settings.margin, maxCandidates: settings.maxCandidates,
                                        acceptThreshold: settings.acceptThreshold, timeoutMs: settings.timeoutMs)
        }
        var would: JudgeWouldAsk??
        if proof.judge == nil, let wouldAsk {
            would = .some(wouldAsk.map { JudgeWouldAsk(trigger: $0.trigger, offered: $0.offered) })
        }
        return Explanation(
            intent: intent, outcome: resolution.outcome, decision: proof.decision, tier: resolution.tier, chosen: resolution.chosen,
            reason: resolution.reason, candidates: candidates, thresholds: proof.thresholds, guards: proof.guards, embedder: proof.embedder,
            artifactHash: proof.artifactHash, judgeConfigured: configured, judgeConsulted: proof.judge, judgeWouldAsk: would,
            steps: proof.steps, proofDigest: proof.proofDigest, resolution: resolution
        )
    }
}

extension ToolRuntime {
    /// Explain how an intent resolves: resolved without learning and without
    /// consulting the judge (explain never calls the network; pass a
    /// recorded verdict in `options.judge` to replay one), and whether a
    /// live dispatch would ask the configured judge. Nothing executes.
    public func explain(_ intent: String, options: ResolveOptions = ResolveOptions()) async throws -> Explanation {
        let (resolution, wouldAsk) = try await context.resolveForExplain(intent, options: options)
        return await context.explainResolution(resolution, wouldAsk: wouldAsk)
    }

    /// Explain a resolution already made (the judge's verdict included).
    public func explain(_ resolution: Resolution) async -> Explanation {
        await context.explainResolution(resolution)
    }
}

/// Human-readable explanation (what `smallchat explain` prints).
public func formatExplanation(_ e: Explanation) -> String {
    var lines: [String] = []
    let t = e.thresholds
    lines.append("Intent:      \"\(e.intent)\"")
    lines.append("Artifact:    \(e.artifactHash ?? "(unknown)")")
    if let embedder = e.embedder {
        let sha = embedder.modelSha256.map { ", sha256 \($0.prefix(12))…" } ?? ""
        lines.append("Embedder:    \(embedder.kind) \(embedder.model) (\(embedder.dims) dims\(sha))")
    }
    lines.append("Thresholds:  EXACT \(t.exact)  HIGH \(t.high)  MEDIUM \(t.medium)  LOW \(t.low)")
    lines.append("Guards:      LLM verifier \(e.guards.llmVerifier ? "configured" : "none")"
        + (e.guards.requireLLMForSubHighDispatch ? " (required below HIGH)" : "")
        + ", strict \(e.guards.strict ? "on" : "off")"
        + (e.guards.treatUnannotatedAsDestructive ? ", unannotated tools count as destructive" : ""))
    if let j = e.judgeConfigured {
        lines.append("Judge:       \(j.name) (\(j.model)), margin \(j.margin), up to \(j.maxCandidates) offered, accepts >= \(j.acceptThreshold), waits up to \(j.timeoutMs)ms")
    }
    if let consulted = e.judgeConsulted {
        let said: String
        switch consulted.verdict {
        case .approved: said = "approved \(consulted.toolId ?? "")"
        case .declined: said = "declined"
        case .unavailable: said = "unavailable; decided as without a judge"
        }
        var why: [String] = []
        if consulted.verdict != .approved, let reason = consulted.reason { why.append(reason) }
        if let p = consulted.probability { why.append("probability \(String(format: "%.3f", p))") }
        let who = e.judgeConfigured == nil ? "\(consulted.name) (\(consulted.model)) " : ""
        lines.append("Judge said:  \(who)\(said)\(why.isEmpty ? "" : " (\(why.joined(separator: ", ")))")")
    } else if e.judgeConfigured != nil {
        switch e.judgeWouldAsk {
        case nil: lines.append("Judge said:  not consulted for this resolution")
        case .some(nil): lines.append("Judge said:  not consulted (explain never calls it); a live dispatch would not ask it")
        case .some(let would?): lines.append("Judge said:  not consulted (explain never calls it); a live dispatch would ask it (\(would.trigger.rawValue)) to choose among \(would.offered.joined(separator: ", "))")
        }
    }
    lines.append("")
    lines.append("Outcome:     \(e.outcome.rawValue)  (decision \(e.decision.rawValue), tier \(e.tier.rawValue.uppercased()))")
    if let chosen = e.chosen { lines.append("Chosen:      \(chosen)") }
    if let reason = e.reason { lines.append("Reason:      \(reason)") }
    lines.append("")
    if e.candidates.isEmpty {
        lines.append("No candidates scored at or above the LOW threshold.")
        let near = e.resolution.refinement?.nearMatches ?? []
        if !near.isEmpty {
            lines.append("Nearest tools (offered as options, not candidates):")
            for n in near { lines.append("  \(n.toolId)  \(String(format: "%.4f", n.confidence))") }
        }
    } else {
        func hints(_ c: ExplainedCandidate) -> String {
            var parts: [String] = []
            if c.annotations?.readOnlyHint == true { parts.append("read-only") }
            if c.destructive { parts.append("destructive") }
            if c.annotations?.idempotentHint == true { parts.append("idempotent") }
            if c.pinned { parts.append("pinned") }
            return parts.isEmpty ? "—" : parts.joined(separator: ",")
        }
        let rows: [[String]] = e.candidates.map { c in [
            c.rank.map(String.init) ?? "-",
            "\(c.chosen ? "*" : " ")\(c.toolId)",
            String(format: "%.4f", c.candidate.score),
            c.candidate.similarity.map { String(format: "%.4f", $0) } ?? "—",
            c.candidate.tier.rawValue.uppercased(),
            c.candidate.source.rawValue,
            hints(c),
            c.candidate.excluded.map { "excluded: \($0)" } ?? c.verdict?.code.rawValue ?? "—",
        ] }
        let header = ["#", " tool", "score", "sim", "tier", "source", "hints", "policy"]
        let widths = header.indices.map { i in max(header[i].count, rows.map { $0[i].count }.max() ?? 0) }
        func fmt(_ r: [String]) -> String {
            "  " + r.enumerated().map { i, cell in i == r.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }
        lines.append(fmt(header))
        for r in rows { lines.append(fmt(r)) }
        lines.append("")
        lines.append("Policy verdicts (running each candidate without the caller naming it):")
        for c in e.candidates {
            if let v = c.verdict { lines.append("  \(c.toolId): \(v.allow ? "allowed" : "refused") — \(v.reason)") }
        }
    }
    lines.append("")
    lines.append("Steps:")
    for step in e.steps { lines.append("  \(step.stage.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(step.decision)") }
    lines.append("")
    lines.append("Proof digest: \(e.proofDigest)")
    return lines.joined(separator: "\n")
}

extension Explanation {
    /// The explanation as JSON (`smallchat explain --json`), never a credential.
    public var jsonValue: AnyCodableValue {
        func optional(_ s: String?) -> AnyCodableValue { s.map { .string($0) } ?? .null }
        var judgeWouldAsk: AnyCodableValue = .null
        if case .some(let would) = self.judgeWouldAsk {
            judgeWouldAsk = would.map { .dict(["trigger": .string($0.trigger.rawValue), "offered": .array($0.offered.map { .string($0) })]) } ?? .bool(false)
        }
        return .dict([
            "intent": .string(intent),
            "outcome": .string(outcome.rawValue),
            "decision": .string(decision.rawValue),
            "tier": .string(tier.rawValue),
            "chosen": optional(chosen),
            "reason": optional(reason),
            "candidates": .array(candidates.map { c in
                .dict([
                    "toolId": .string(c.toolId),
                    "rank": c.rank.map { .int($0) } ?? .null,
                    "chosen": .bool(c.chosen),
                    "score": .double(c.candidate.score),
                    "similarity": c.candidate.similarity.map { .double($0) } ?? .null,
                    "tier": .string(c.candidate.tier.rawValue),
                    "source": .string(c.candidate.source.rawValue),
                    "excluded": optional(c.candidate.excluded),
                    "annotations": c.annotations.map { .dict($0.jsonValue) } ?? .null,
                    "destructive": .bool(c.destructive),
                    "pinned": .bool(c.pinned),
                    "policy": c.verdict.map { .dict(["allow": .bool($0.allow), "code": .string($0.code.rawValue), "reason": .string($0.reason), "tier": .string($0.tier.rawValue)]) } ?? .null,
                ])
            }),
            "thresholds": .dict(["exact": .double(thresholds.exact), "high": .double(thresholds.high), "medium": .double(thresholds.medium), "low": .double(thresholds.low)]),
            "guards": .dict([
                "requireLLMForSubHighDispatch": .bool(guards.requireLLMForSubHighDispatch),
                "strict": .bool(guards.strict),
                "llmVerifier": .bool(guards.llmVerifier),
                "treatUnannotatedAsDestructive": .bool(guards.treatUnannotatedAsDestructive),
            ]),
            "embedder": embedder.map { .dict($0.jsonValue) } ?? .null,
            "artifactHash": optional(artifactHash),
            "judgeConfigured": judgeConfigured.map { .dict([
                "name": .string($0.name), "model": .string($0.model), "margin": .double($0.margin),
                "maxCandidates": .int($0.maxCandidates), "acceptThreshold": .double($0.acceptThreshold), "timeoutMs": .int($0.timeoutMs),
            ]) } ?? .null,
            "judgeConsulted": judgeConsulted.map(\.jsonValue) ?? .null,
            "judgeWouldAsk": judgeWouldAsk,
            "steps": .array(steps.map(\.jsonValue)),
            "proofDigest": .string(proofDigest),
        ])
    }
}
