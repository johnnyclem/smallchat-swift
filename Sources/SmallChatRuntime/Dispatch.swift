import Foundation
import SmallChatCore

// MARK: - Resolution types

/// Options for `DispatchContext.resolve(_:options:)`.
public struct ResolveOptions: Sendable {
    /// Consult and update the resolution cache (dispatch does; a plain
    /// `resolve` does not, so it changes nothing in the runtime beyond the
    /// opt-in rate limiter's window). Intents are never interned either way.
    public var learn: Bool
    /// The arguments the call will carry, when known: used to choose among
    /// overloads and by verification's required-parameter check.
    public var args: [String: any Sendable]?
    /// Who is asking (scopes the rate limiter).
    public var principal: String?
    /// The shortlist judge for this call. Nil: the runtime's
    /// (RuntimeOptions.judge). `.off`: no judge; the call decides as a
    /// runtime without one. `.recorded`: a recorded verdict answers in the
    /// judge's place and no judge is called, which is how replay
    /// reproduces judged decisions without the network.
    public var judge: JudgeOverride?

    public init(learn: Bool = false, args: [String: any Sendable]? = nil, principal: String? = nil, judge: JudgeOverride? = nil) {
        self.learn = learn
        self.args = args
        self.principal = principal
        self.judge = judge
    }
}

/// `ResolveOptions.judge`: no judge, or a recorded verdict in its place.
public enum JudgeOverride: Sendable, Equatable {
    case off
    case recorded(RecordedJudgeVerdict)
}

/// What `resolve(intent)` decided. Nothing has executed.
public struct Resolution: Sendable {
    public let outcome: ResolutionOutcome
    public let intent: String
    /// Tier of the chosen (or best) candidate
    public let tier: DispatchTier
    /// Canonical tool id resolution chose -- only when `outcome` is `.resolved`
    public let chosen: String?
    /// Score of the chosen candidate
    public let confidence: Double?
    /// Eligible candidates, best first (excluded ones are listed in the proof)
    public let candidates: [ProofCandidate]
    public let proof: ResolutionProof
    /// Why the runtime would not pick a tool on its own
    public let reason: String?
    /// Options to present to the user; each near match carries a tool id
    public let refinement: ToolRefinement?
    /// `.throttled`: milliseconds until this principal may try again
    public let retryAfterMs: Int?
}

/// The `metadata["outcome"]` of a dispatch result. Only `.resolved` means a
/// tool ran (its own failure is `isError` with outcome `.resolved`); every
/// other outcome ran nothing and is `isError`.
public enum DispatchOutcomeCode: String, Sendable {
    case resolved
    case needsDisambiguation = "needs-disambiguation"
    case unresolved
    case throttled
    /// The arguments failed the tool's inputSchema
    case invalidArguments = "invalid-arguments"
    /// The calling task was cancelled before the tool started
    case aborted
    /// A decomposition sub-intent past `maxSubDispatches`
    case notDispatched = "not-dispatched"
}

/// Options for `dispatchById`.
public struct DispatchByIdOptions: Sendable {
    /// proofDigest of the resolution this call acts on (e.g. a `resolve`
    /// proposal the user confirmed). Recorded in the proof.
    public var resolutionDigest: String?
    /// Who the call is for.
    public var principal: String?

    public init(resolutionDigest: String? = nil, principal: String? = nil) {
        self.resolutionDigest = resolutionDigest
        self.principal = principal
    }
}

/// Options for an intent dispatch.
public struct DispatchOptions: Sendable {
    /// Who the dispatch is for (scopes the opt-in rate limiter).
    public var principal: String?

    public init(principal: String? = nil) {
        self.principal = principal
    }
}

/// Keys of the metadata a dispatch result carries.
public enum DispatchMetadataKey {
    /// `DispatchOutcomeCode.rawValue`
    public static let outcome = "outcome"
    /// Canonical tool id that was (or would have been) run
    public static let toolId = "toolId"
    /// `ResolutionProof`
    public static let proof = "proof"
    /// Canonical call digest of what ran
    public static let callDigest = "callDigest"
    /// `DispatchTier.rawValue`
    public static let tier = "tier"
    public static let confidence = "confidence"
    /// `[ValidationError]` (outcome invalid-arguments)
    public static let validationErrors = "validationErrors"
    /// `ToolRefinement` (outcome needs-disambiguation / unresolved)
    public static let refinement = "refinement"
    /// `Int` (outcome throttled)
    public static let retryAfterMs = "retryAfterMs"
    /// `JudgeMetadata` when a shortlist judge took part: who it was, its verdict and the tool it chose
    public static let judge = "judge"
}

/// `metadata["judge"]` of a dispatch result a shortlist judge took part in.
public struct JudgeMetadata: Sendable, Equatable {
    public var name: String
    public var verdict: JudgeRecord.Verdict
    public var toolId: String?
}

// MARK: - Internal state

struct Candidate: Sendable {
    let imp: any ToolIMP
    let toolId: String
    /// The tool selector the candidate matched through
    let selector: ToolSelector
    /// Quantized score
    var score: Double
    var similarity: Double?
    var source: CandidateSource
}

struct InternalResolution: Sendable {
    let resolution: Resolution
    /// The chosen IMP when resolved
    let imp: (any ToolIMP)?
    /// Set when dispatch should run these sub-intents instead of one tool
    let decomposition: [String]?
}

struct ResolveRun: Sendable {
    var learn: Bool
    var args: [String: any Sendable]?
    var principal: String?
    /// Dispatch (not resolve) may decompose LOW-tier and unmatched intents
    var allowDecomposition: Bool
    /// Decomposition depth of this dispatch (sub-intents are depth + 1)
    var depth: Int
    /// intentKeys of the intents this one was decomposed from
    var ancestors: [String]
    /// ResolveOptions.judge (nil: the runtime's judge, asked live)
    var judge: JudgeOverride? = nil
    /// explain(intent): with `.off`, note whether the runtime's judge would have been asked
    var judgeProbe: JudgeProbe? = nil
}

/// Whether a live dispatch would ask the runtime's judge (explain never asks it).
final class JudgeProbe: @unchecked Sendable {
    /// Set when it would: the trigger and the offered tool ids. Nil when not.
    var wouldAsk: (trigger: JudgeTrigger, offered: [String])?
}

/// Mutable state of one resolution (proof, exclusions, the intent's own vector).
private final class ResolveState: @unchecked Sendable {
    var proof: ResolutionProof
    var excluded: [ProofCandidate] = []
    var ownVector: [Float]?
    var clock = ProofTimer()

    init(proof: ResolutionProof) {
        self.proof = proof
    }

    func step(_ stage: ProofStage, _ decision: String, _ detail: [String: AnyCodableValue]? = nil) {
        proof.addStep(stage, decision, detail: detail, elapsedMs: clock.lap())
    }
}

/// Nearest tools offered as refinement options start at this similarity.
let refinementFloor = 0.3
/// The cutoff `dispatch` uses when it stamps `metadata["ambiguous"]`: more
/// than one candidate and a winner at or under this score. A flag for
/// callers; it decides nothing (the judge's trigger is `judgeTrigger`).
public let ambiguousConfidence = 0.90
/// How many vector matches resolution considers.
let searchTopK = 5

// MARK: - Resolution -- pure: chooses a tool (or refuses to), never executes

extension DispatchContext {

    /// Resolve an intent to at most one tool. Never executes anything.
    ///
    /// Order: pinned phrase -> cache (when learning) -> (opt-in rate limit)
    /// -> ranked candidates (vector and overload matches, protocol
    /// conformance). Every candidate passes the pin gate; the chosen one
    /// passes verification (below HIGH, or below EXACT in strict mode) and
    /// the dispatch policy (`evaluateDispatchPolicy`). Anything the policy
    /// refuses is needs-disambiguation.
    ///
    /// Determinism: for the same tools, embedder and runtime state (pins,
    /// cache, options), the same intent text yields the same outcome,
    /// candidates and proofDigest. Scores are quantized to 1e-4 and ties
    /// ordered by canonical tool id; other intents the process has seen do
    /// not enter into it. An LLM verifier's answers are an input like any
    /// other.
    public func resolve(_ intent: String, options: ResolveOptions = ResolveOptions()) async throws -> Resolution {
        let r = try await resolveInternal(intent, run: ResolveRun(
            learn: options.learn,
            args: options.args,
            principal: options.principal,
            allowDecomposition: false,
            depth: 0,
            ancestors: [],
            judge: options.judge
        ))
        try await decisionLog?.record(kind: .resolve, proof: r.resolution.proof, execution: .none, principal: options.principal)
        return r.resolution
    }

    /// Resolve as `explain(intent)` does: learning off, no judge asked (a
    /// recorded verdict in `options.judge` still answers in its place), and
    /// whether a live dispatch would ask the runtime's judge noted.
    func resolveForExplain(_ intent: String, options: ResolveOptions) async throws -> (resolution: Resolution, wouldAsk: (trigger: JudgeTrigger, offered: [String])??) {
        let judge = options.judge ?? JudgeOverride.off
        let probe: JudgeProbe? = (options.judge == nil && self.judge != nil) ? JudgeProbe() : nil
        let r = try await resolveInternal(intent, run: ResolveRun(
            learn: false, args: options.args, principal: options.principal, allowDecomposition: false, depth: 0, ancestors: [],
            judge: judge, judgeProbe: probe
        ))
        try await decisionLog?.record(kind: .resolve, proof: r.resolution.proof, execution: .none, principal: options.principal)
        return (r.resolution, probe.map { $0.wouldAsk })
    }

    func resolveInternal(_ rawIntent: String, run: ResolveRun) async throws -> InternalResolution {
        let intent = try validateIntent(rawIntent)
        let state = ResolveState(proof: newProof(intent: intent))
        let config = dispatchConfig
        let thresholds = config.thresholds
        let policy = policyOptions
        let llm = llmClient
        let args = run.args
        let hasArgs = !(args?.isEmpty ?? true)
        let key = intentKey(intent)
        // The registry this resolution decides against; it caches only if
        // the registry is unchanged when it is done.
        let generation = registryGeneration

        func embedOwn() async throws -> [Float] {
            if let vector = state.ownVector { return vector }
            let vector = try await embedder.embed(intent)
            state.ownVector = vector
            return vector
        }
        func ownSimilarity(_ selector: ToolSelector) async throws -> Double {
            quantizeScore(cosineSimilarityDouble(try await embedOwn(), selector.vector))
        }
        func toProof(_ c: Candidate, excludedBy: String? = nil) -> ProofCandidate {
            ProofCandidate(
                toolId: c.toolId,
                selector: c.selector.canonical,
                score: c.score,
                similarity: c.similarity,
                tier: computeTier(c.score, thresholds: thresholds),
                source: c.source,
                excluded: excludedBy
            )
        }
        func rank(_ candidates: [Candidate]) -> [Candidate] {
            candidates.sorted { rankedBefore(score: $0.score, toolId: $0.toolId, score: $1.score, toolId: $1.toolId) }
        }
        func subHigh(_ tier: DispatchTier) -> Bool { tier == .medium || tier == .low }

        /// Pin gate + dispatch policy for one candidate.
        func judge(_ c: Candidate, llmApproved: Bool) async throws -> PolicyVerdict {
            var similarity = c.similarity
            let via = c.selector.canonical
            let destructive = isDestructive(c.imp.annotations, treatUnannotatedAsDestructive: config.treatUnannotatedAsDestructive)
            if similarity != nil && (destructive || isPinnedTool(c.toolId, via: via)) {
                // Always measured from this intent's own text.
                similarity = try await ownSimilarity(c.selector)
            }
            let pins = try await pinStates(for: c.toolId, intent: intent, via: via, ownSimilarity: ownSimilarity)
            return evaluateDispatchPolicy(
                PolicyInput(mode: .intent, toolId: c.toolId, annotations: c.imp.annotations, source: c.source,
                            score: c.score, similarity: similarity, llmApproved: llmApproved, pins: pins),
                options: policy
            )
        }

        func finish(
            _ outcome: ResolutionOutcome,
            _ decision: DecisionCode,
            ranked: [Candidate],
            chosen: Candidate?,
            reason: String? = nil,
            refinement: ToolRefinement? = nil,
            decomposition: [String]? = nil,
            retryAfterMs: Int? = nil
        ) -> InternalResolution {
            let best = chosen ?? ranked.first
            state.proof.outcome = outcome
            state.proof.decision = decision
            state.proof.tier = best.map { computeTier($0.score, thresholds: thresholds) } ?? .none
            state.proof.chosen = outcome == .resolved ? chosen?.toolId : nil
            state.proof.confidence = outcome == .resolved ? chosen?.score : nil
            state.proof.candidates = ranked.map { toProof($0) } + state.excluded
            state.proof.finalize()
            var finalRefinement = refinement
            if let r = refinement {
                finalRefinement = ToolRefinement(originalIntent: r.originalIntent, reason: r.reason,
                                                 clarifyingQuestions: r.clarifyingQuestions, nearMatches: r.nearMatches,
                                                 proof: state.proof)
            }
            let resolution = Resolution(
                outcome: outcome,
                intent: intent,
                tier: state.proof.tier,
                chosen: state.proof.chosen,
                confidence: state.proof.confidence,
                candidates: ranked.map { toProof($0) },
                proof: state.proof,
                reason: reason,
                refinement: finalRefinement,
                retryAfterMs: retryAfterMs
            )
            return InternalResolution(resolution: resolution, imp: outcome == .resolved ? chosen?.imp : nil, decomposition: decomposition)
        }

        func disambiguate(_ decision: DecisionCode, _ ranked: [Candidate], reason: String) async -> InternalResolution {
            let refinement = await makeRefinement(
                originalIntent: intent,
                candidates: ranked.map { ToolCandidate(imp: $0.imp, confidence: $0.score, selector: $0.selector) },
                proof: state.proof,
                llm: llm,
                reason: "\(reason). Choose a tool and call it by id."
            )
            return finish(.needsDisambiguation, decision, ranked: ranked, chosen: nil, reason: reason, refinement: refinement)
        }

        /// Ask the LLM to split the intent, keeping only sub-intents that
        /// differ from it and from every intent it was itself split from.
        func tryDecompose() async -> [String]? {
            guard run.allowDecomposition, run.depth < config.maxDecompositionDepth else { return nil }
            let proposed: [String]
            switch await llm.decompose(intent: intent) {
            case .unavailable: return nil
            case .atomic: proposed = []
            case .decomposed(let subIntents): proposed = subIntents
            }
            let seen = Set([key] + run.ancestors)
            let kept = proposed.filter { !$0.isEmpty && !seen.contains(intentKey($0)) }
            let detail: [String: AnyCodableValue] = ["depth": .int(run.depth), "proposed": .int(proposed.count), "kept": .int(kept.count)]
            if !kept.isEmpty {
                state.step(.decomposition, "Decomposed into \(kept.count) sub-intent(s) (llm)", detail)
                return kept
            }
            state.step(.decomposition, proposed.isEmpty
                ? "Decomposition produced no sub-intents"
                : "Decomposition only restated the intent (\(proposed.count) sub-intent(s) refused)", detail)
            return nil
        }

        // 1. PINNED PHRASE -- the intent is, verbatim, a pinned phrase.
        if intentPins.size > 0, let pinMatch = intentPins.checkExact(intent),
           let owner = await toolForSelector(pinMatch.canonical) {
            let c = Candidate(imp: owner.imp, toolId: owner.toolId, selector: owner.selector, score: 1, similarity: nil, source: .pin)
            let verdict = try await judge(c, llmApproved: false)
            state.step(.intentPin, "\"\(intent)\" is a pinned phrase of \(pinMatch.canonical) → \(c.toolId)",
                       ["pin": .string(pinMatch.canonical), "policy": .string(pinMatch.policy.rawValue)])
            if verdict.allow { return finish(.resolved, .pinExact, ranked: [c], chosen: c) }
            state.step(.policy, verdict.reason, ["code": .string(verdict.code.rawValue), "toolId": .string(c.toolId)])
            return await disambiguate(verdict.decision, [c], reason: verdict.reason)
        }

        // 2. CACHE -- a previous HIGH/EXACT resolution of this exact intent
        // text (no-argument calls only: with arguments, overload choice
        // depends on them), stored under the current registry generation
        // and of a tool the index still holds. Re-judged by the policy on
        // every hit.
        var cachedEntry: ResolvedTool?
        if run.learn && !hasArgs { cachedEntry = await cache.lookup(key: key) }
        if let stale = cachedEntry, stale.registryGeneration != registryGeneration || !isRegistered(stale.imp) {
            // Decided before the registry last changed (a resolution that
            // raced registerClass/unregisterClass/reindex), or stored by
            // someone else: a miss.
            await cache.flushSelector(stale.selector)
            state.step(.cache, "Cached \(stale.imp.toolId) not used: it was not resolved against the current tool registry",
                       ["toolId": .string(stale.imp.toolId)])
            cachedEntry = nil
        }
        if let cached = cachedEntry {
            let id = cached.imp.toolId
            var selector = cached.selector
            if let primary = getTool(id)?.selectors.first, let toolSelector = await selectorTable.get(primary) {
                selector = toolSelector
            }
            let c = Candidate(imp: cached.imp, toolId: id, selector: selector, score: quantizeScore(cached.confidence), similarity: nil, source: .cache)
            let usable = !(config.strict && computeTier(c.score, thresholds: thresholds) != .exact)
            let verdict = try await judge(c, llmApproved: false)
            if usable && verdict.allow {
                state.step(.cache, "Cache hit → \(c.toolId) at \(fixed3(c.score))", ["toolId": .string(c.toolId)])
                return finish(.resolved, .cache, ranked: [c], chosen: c)
            }
            state.step(.cache, "Cached \(c.toolId) not used: \(usable ? verdict.reason : "strict mode verifies below EXACT")",
                       ["toolId": .string(c.toolId), "code": .string(verdict.code.rawValue)])
        }

        // 3. RATE LIMIT (opt-in) -- a novel intent is about to be embedded.
        // Admission takes the window slot at once, so concurrent intents
        // from one principal can't all pass before any is counted.
        let principal = run.principal ?? defaultPrincipal
        var reservation: RateLimitReservation?
        if let rateLimiter, state.ownVector == nil {
            switch await rateLimiter.admit(key, principal: principal) {
            case .denied(let reason, let retryAfterMs):
                state.step(.rateLimit, "Rate limit (\(reason)) reached for this principal; the intent was not embedded", ["reason": .string(reason)])
                return finish(.throttled, .rateLimited, ranked: [], chosen: nil,
                              reason: "Too many novel intents (\(reason)); retry in \(Int((Double(retryAfterMs) / 1000).rounded(.up)))s",
                              retryAfterMs: retryAfterMs)
            case .admitted(let slot):
                reservation = slot
            }
        }

        // 4. EMBED the intent -- its own vector, never interned.
        let vector: [Float]
        do {
            vector = try await embedOwn()
        } catch {
            if let reservation { await rateLimiter?.release(reservation) }
            throw error
        }
        let selector = ToolSelector.intent(intent, vector: vector)
        if let reservation {
            await rateLimiter?.record(reservation, vector: vector)
        } else {
            await rateLimiter?.record(key, vector, principal: principal)
        }

        // 5. VECTOR SEARCH -- every match (and overload) becomes a ranked candidate.
        let floor = config.strict ? thresholds.medium : thresholds.low
        let nearest = try await selectorTable.searchTools(selector.vector, topK: searchTopK, threshold: min(floor, refinementFloor))
        let matches = nearest.filter { quantizeScore(1 - Double($0.distance)) >= floor }
        var byTool: [String: Candidate] = [:]
        func offer(_ c: Candidate) {
            if let existing = byTool[c.toolId], existing.score >= c.score { return }
            byTool[c.toolId] = c
        }

        for match in matches {
            guard let matchSelector = await selectorTable.get(match.id) else { continue }
            let similarity = quantizeScore(1 - Double(match.distance))
            for toolClass in classesForSelector(match.id) {
                var imp: (any ToolIMP)?
                var source = CandidateSource.vector
                if hasArgs, let args, toolClass.hasOverloads(matchSelector) {
                    do {
                        if let overload = try toolClass.validateAndResolveSelectorWithNamedArgs(matchSelector, namedArgs: args) {
                            imp = overload.imp
                            source = .overload
                            state.step(.overload, "Overload of \(match.id) for these arguments → \(overload.imp.toolId) (\(overload.signature.signatureKey))",
                                       ["selector": .string(match.id), "signature": .string(overload.signature.signatureKey)])
                        }
                    } catch is OverloadAmbiguityError {
                        state.step(.overload, "Overloads of \(match.id) are ambiguous for these arguments", ["selector": .string(match.id)])
                        continue
                    } catch let error as SignatureValidationError {
                        state.step(.overload, "No overload of \(match.id) accepts these argument types",
                                   ["selector": .string(match.id), "violations": .array(error.errors.map { .string("\($0.path): \($0.message)") })])
                        continue
                    }
                }
                guard let chosenImp = imp ?? toolClass.resolveSelector(matchSelector) else { continue }
                offer(Candidate(imp: chosenImp, toolId: chosenImp.toolId, selector: matchSelector, score: similarity, similarity: similarity, source: source))
            }
        }
        state.step(.vectorSearch, "Vector search found \(byTool.count) candidate tool(s) at or above \(ecmaNumber(floor))", [
            "floor": .double(floor),
            "matches": .array(matches.map { .dict(["selector": .string($0.id), "similarity": .double(quantizeScore(1 - Double($0.distance)))]) }),
        ])

        // 6. PROTOCOL CONFORMANCE -- only when nothing matched by vector.
        if byTool.isEmpty, let protocolMatch = resolveViaProtocol(selector) {
            let c = Candidate(imp: protocolMatch.imp, toolId: protocolMatch.imp.toolId, selector: protocolMatch.selector,
                              score: quantizeScore(protocolMatch.confidence), similarity: nil, source: .protocol)
            offer(c)
            state.step(.protocol, "Protocol conformance → \(c.toolId) at \(fixed3(c.score))", ["selector": .string(protocolMatch.selector.canonical)])
        }

        // 7. PIN GATE -- a pinned tool is never a candidate for an intent its pin refuses.
        var eligible: [Candidate] = []
        for c in rank(Array(byTool.values)) {
            let via = c.selector.canonical
            guard isPinnedTool(c.toolId, via: via) else {
                eligible.append(c)
                continue
            }
            let pins = try await pinStates(for: c.toolId, intent: intent, via: via, ownSimilarity: ownSimilarity)
            if let refused = pins.first(where: { !$0.satisfied }) {
                let code: DecisionCode = refused.policy == .exact ? .pinExactRequired : .pinElevatedRequired
                state.excluded.append(toProof(c, excludedBy: code.rawValue))
                state.step(.intentPin, "\(c.toolId) excluded: pinned '\(refused.policy.rawValue)' (\(refused.canonical)) and this intent does not satisfy it",
                           ["toolId": .string(c.toolId), "pin": .string(refused.canonical)])
            } else {
                eligible.append(c)
            }
        }
        let ranked = rank(eligible)

        // 8. NOTHING MATCHED -- unresolved (refinement options, or decomposition when dispatching).
        guard let best = ranked.first else {
            var near: [ToolCandidate] = []
            for match in nearest {
                guard let owner = await toolForSelector(match.id), !near.contains(where: { $0.imp.toolId == owner.toolId }) else { continue }
                near.append(ToolCandidate(imp: owner.imp, confidence: quantizeScore(1 - Double(match.distance)), selector: owner.selector))
            }
            let reason = "No tool matched \"\(intent)\""
            let refinement = await makeRefinement(originalIntent: intent, candidates: near, proof: state.proof, llm: llm,
                                                  reason: "I couldn't find an exact match for \"\(intent)\". Did you mean one of these?")
            if !refinement.nearMatches.isEmpty || !refinement.clarifyingQuestions.isEmpty {
                state.step(.refinement, "No candidate above \(ecmaNumber(floor)); \(refinement.nearMatches.count) refinement option(s)")
                return finish(.unresolved, .noCandidates, ranked: ranked, chosen: nil, reason: reason, refinement: refinement)
            }
            if let subIntents = await tryDecompose() {
                return finish(.resolved, .decomposed, ranked: ranked, chosen: nil, decomposition: subIntents)
            }
            state.step(.refinement, "No candidate above \(ecmaNumber(floor)) and no refinement options")
            return finish(.unresolved, .noCandidates, ranked: ranked, chosen: nil, reason: reason)
        }

        let bestTier = computeTier(best.score, thresholds: thresholds)

        // 9. LOW-tier decomposition (dispatch only): a compound intent may need several tools.
        if bestTier == .low, let subIntents = await tryDecompose() {
            return finish(.resolved, .decomposed, ranked: ranked, chosen: nil, decomposition: subIntents)
        }

        // 10. JUDGE (optional; Judge.swift, spec/judge) -- a below-HIGH winner,
        // or a HIGH winner with a runner-up within the margin; never EXACT,
        // and never a winner the policy refuses. The judge may only pick
        // among near-ties of the winner it could then run. Unavailable:
        // decide as without a judge. Declined: needs-disambiguation. A
        // recorded verdict (replay) answers in the judge's place.
        var chosen: Candidate? = best
        var llmApproved = false
        var judgeAsked = false
        var judgeApproved = false
        let verifiedTier: (DispatchTier) -> Bool = { subHigh($0) || (config.strict && $0 != .exact) }
        var recorded: RecordedJudgeVerdict?
        var liveJudge: (any ShortlistJudge)?
        var probe: JudgeProbe?
        switch run.judge {
        case nil: liveJudge = self.judge
        case .off?: probe = run.judgeProbe
        case .recorded(let verdict)?: recorded = verdict
        }
        let settings: JudgeSettings? = recorded.map { recordedJudgeSettings($0, configured: judgeSettings) } ?? (liveJudge != nil || probe != nil ? judgeSettings : nil)
        if let settings {
            let trigger = judgeTrigger(tier: bestTier, bestScore: best.score, runnerUpScore: ranked.count > 1 ? ranked[1].score : nil, margin: settings.margin)
            var offered: [Candidate] = []
            if trigger != nil {
                offered = await shortlistFor(ranked, settings: settings,
                    allowed: { c in (try? await judge(c, llmApproved: true))?.allow ?? false },
                    passes: { c in
                        // What an approval still has to pass: the required parameters when the
                        // arguments are known and, where the tier is verified, keyword overlap.
                        let verifiedHere = verifiedTier(computeTier(c.score, thresholds: thresholds))
                        return await verify(c.imp, intent: intent, args: args ?? [:], llm: NoOpLLMClient(), options: VerificationOptions(
                            skipLLMCheck: true, skipSchemaCheck: args == nil, minOverlap: verifiedHere ? 0.15 : 0
                        )).pass
                    })
            }
            let ids = offered.map(\.toolId)
            // A HIGH winner alone is no near-tie: the judge is asked only to choose among two or more.
            let asks = !offered.isEmpty && (subHigh(bestTier) || offered.count > 1)
            if let trigger, asks, let probe {
                probe.wouldAsk = (trigger, ids)
            } else if let trigger, asks {
                judgeAsked = true
                // A recorded verdict is recorded under its own name and model, never the runtime judge's.
                let name = recorded.map { $0.name ?? "recorded" } ?? liveJudge!.name
                let configuredModel = recorded.map { $0.model ?? "unknown" } ?? liveJudge!.model
                var contextName: String?
                let judged: JudgeVerdict
                if let recorded {
                    judged = replayJudgeVerdict(recorded, offered: ids, model: configuredModel)
                } else {
                    var described: [JudgeCandidate] = []
                    for c in offered {
                        var schema = c.imp.schema
                        if schema == nil { schema = try? await c.imp.loadSchema() }
                        let description = (schema?.description).flatMap { $0.isEmpty ? nil : $0 } ?? c.selector.canonical
                        described.append(JudgeCandidate(toolId: c.toolId, description: judgeDescription(description)))
                    }
                    let asked = await askJudge(liveJudge!, request: JudgeRequest(intent: intent, trigger: trigger, candidates: described),
                                               timeoutMs: settings.timeoutMs, provider: judgeContext, principal: run.principal)
                    contextName = asked.contextName
                    judged = acceptJudgeAnswer(asked.answer, offered: ids, acceptThreshold: settings.acceptThreshold, configuredModel: configuredModel)
                }
                state.proof.judge = JudgeRecord(
                    name: name, model: judged.model, verdict: judged.verdict, toolId: judged.toolId, probability: judged.probability,
                    confidence: judged.confidence, reason: judged.reason, margin: settings.margin, maxCandidates: settings.maxCandidates, requestId: judged.requestId
                )
                var detail: [String: AnyCodableValue] = [
                    "judge": .string(name),
                    "model": .string(judged.model),
                    "verdict": .string(judged.verdict.rawValue),
                    "toolId": judged.toolId.map { .string($0) } ?? .null,
                    "trigger": .string(trigger.rawValue),
                    "offered": .array(ids.map { .string($0) }),
                ]
                if let contextName { detail["context"] = .string(contextName) }
                state.step(.judge, judgeStepText(name: name, judged: judged, offered: ids.count, trigger: trigger), detail)
                if judged.verdict == .declined {
                    return await disambiguate(.judgeDeclined, ranked,
                        reason: "The \(name) judge chose none of the \(ids.count) offered tool(s) for \"\(intent)\" (\(judged.reason ?? "no reason recorded"))")
                }
                if judged.verdict == .approved, let approved = offered.first(where: { $0.toolId == judged.toolId }) {
                    chosen = approved
                    judgeApproved = true
                    llmApproved = true
                }
            }
        }

        // 11. VERIFICATION -- below HIGH, or below EXACT in strict mode. The
        // best candidate and every alternate get the same strategies, the LLM
        // included. A judge's approval stands in for the LLM check only: its
        // choice still gets the deterministic strategies wherever the ranked
        // winner would.
        if judgeApproved, let pick = chosen {
            if verifiedTier(computeTier(pick.score, thresholds: thresholds)) {
                let v = await verify(pick.imp, intent: intent, args: args ?? [:], llm: NoOpLLMClient(),
                                     options: VerificationOptions(skipLLMCheck: true, skipSchemaCheck: args == nil))
                state.step(.verification, v.pass
                    ? "Verification passed for \(pick.toolId) (overlap \(Int((v.descriptionOverlap * 100).rounded()))%, judge approved)"
                    : "Verification failed for \(pick.toolId): \(v.reason ?? "")", [
                        "toolId": .string(pick.toolId),
                        "pass": .bool(v.pass),
                        "schemaMatch": .bool(v.schemaMatch),
                        "descriptionOverlap": .double(v.descriptionOverlap),
                        "llmConfirmed": .null,
                    ])
                if !v.pass {
                    return await disambiguate(.verificationFailed, ranked, reason: "\(pick.toolId), the judge's choice for \"\(intent)\", failed verification")
                }
            }
        } else if verifiedTier(bestTier) {
            let llmVerifier = llm.providesVerification
            if subHigh(bestTier) && config.requireLLMForSubHighDispatch && !llmVerifier {
                state.step(.verification, "Best candidate is \(bestTier.rawValue); no LLM verifier is configured to approve it")
            } else {
                chosen = nil
                for c in ranked {
                    let tier = computeTier(c.score, thresholds: thresholds)
                    if tier == .none { break }
                    if subHigh(tier) && config.requireLLMForSubHighDispatch && !llmVerifier { break }
                    let forceLLM = subHigh(tier) && config.requireLLMForSubHighDispatch
                    let v = await verify(c.imp, intent: intent, args: args ?? [:], llm: llm, options: VerificationOptions(
                        skipLLMCheck: !llmVerifier,
                        forceLLMCheck: forceLLM,
                        skipSchemaCheck: args == nil
                    ))
                    state.step(.verification, v.pass
                        ? "Verification passed for \(c.toolId) (overlap \(Int((v.descriptionOverlap * 100).rounded()))%\(v.llmConfirmed == true ? ", LLM approved" : ""))"
                        : "Verification failed for \(c.toolId): \(v.reason ?? "")", [
                            "toolId": .string(c.toolId),
                            "pass": .bool(v.pass),
                            "schemaMatch": .bool(v.schemaMatch),
                            "descriptionOverlap": .double(v.descriptionOverlap),
                            "llmConfirmed": v.llmConfirmed.map { .bool($0) } ?? .null,
                        ])
                    if v.pass {
                        chosen = c
                        llmApproved = v.llmConfirmed == true
                        break
                    }
                }
                guard chosen != nil else {
                    return await disambiguate(.verificationFailed, ranked, reason: "No candidate for \"\(intent)\" passed verification")
                }
            }
        }

        // 12. POLICY -- the same rule set as every other path.
        let pick = chosen!
        let verdict = try await judge(pick, llmApproved: llmApproved)
        state.step(.policy, verdict.reason, ["code": .string(verdict.code.rawValue), "toolId": .string(pick.toolId)])
        guard verdict.allow else {
            return await disambiguate(verdict.decision, ranked, reason: verdict.reason)
        }

        let pickTier = computeTier(pick.score, thresholds: thresholds)
        let decision: DecisionCode = judgeApproved ? .judgeApproved : llmApproved && subHigh(pickTier) ? .llmVerified : subHigh(pickTier) ? .verified : .ranked

        // Learn: cache plain vector resolutions of ordinary tools (never
        // pinned or destructive ones), and only ones ranking alone decided
        // under the runtime's own judge setting: a resolution the judge took
        // part in is asked again next time, and one a per-call override kept
        // from the runtime's judge must not answer later calls in its place.
        // Only a decision made against the registry as it still is: one that
        // raced a registry change may hold a tool that is gone or outranked.
        let judgeOverridden = self.judge != nil && run.judge != nil
        if run.learn, !judgeAsked, !judgeOverridden, pick.source == .vector, !isPinnedTool(pick.toolId, via: pick.selector.canonical),
           !isDestructive(pick.imp.annotations, treatUnannotatedAsDestructive: config.treatUnannotatedAsDestructive),
           registryGeneration == generation, isRegistered(pick.imp) {
            await cache.store(selector, imp: pick.imp, confidence: pick.score, registryGeneration: generation)
        }

        return finish(.resolved, decision, ranked: ranked, chosen: pick)
    }
}

// MARK: - The shortlist judge's helpers

extension DispatchContext {
    /// D2: the candidates a judge is offered -- near-ties of the winner that
    /// it could choose and then run: each one's schema loads, the policy would
    /// run it on the judge's approval (`allowed`), and the deterministic
    /// checks the approval still gets would pass (`passes`). At most
    /// maxCandidates, best-ranked first, returned sorted by tool id. A winner
    /// whose schema cannot be loaded or that the policy refuses means nothing
    /// is offered: a judge breaks ties, it never overrules a refusal.
    func shortlistFor(
        _ ranked: [Candidate],
        settings: JudgeSettings,
        allowed: (Candidate) async -> Bool,
        passes: (Candidate) async -> Bool
    ) async -> [Candidate] {
        guard let best = ranked.first else { return [] }
        var offered: [Candidate] = []
        for c in ranked {
            if offered.count >= settings.maxCandidates { break }
            if !withinJudgeMargin(best: best.score, score: c.score, margin: settings.margin) { break }
            var schema = c.imp.schema
            if schema == nil { schema = try? await c.imp.loadSchema() }
            var usable = schema != nil
            if usable { usable = await allowed(c) }
            if !usable {
                if c.toolId == best.toolId { return [] }
                continue
            }
            if !(await passes(c)) { continue }
            offered.append(c)
        }
        return offered.sorted { judgeToolIdPrecedes($0.toolId, $1.toolId) }
    }
}

/// Ask a judge, held to `timeoutMs` whatever the judge does: past the
/// deadline the answer is TIMEOUT and the judge's task is cancelled. The
/// context provider is asked first, within the same budget; nil, a throw
/// or a timeout means the judge is asked with the intent alone.
func askJudge(
    _ judge: any ShortlistJudge,
    request: JudgeRequest,
    timeoutMs: Int,
    provider: (any JudgeContextProvider)?,
    principal: String?
) async -> (answer: JudgeAnswer, contextName: String?) {
    if Task.isCancelled { return (.unavailable(error: .aborted), nil) }
    let work: @Sendable () async -> (JudgeAnswer, String?) = {
        var withContext = request
        var contextName: String?
        if let provider {
            if let context = try? await provider.context(intent: request.intent, principal: principal) {
                withContext.context = context
                contextName = provider.name
            }
        }
        if Task.isCancelled { return (.unavailable(error: .timeout), contextName) }
        return (await judge.judge(withContext), contextName)
    }
    return await withTaskGroup(of: (JudgeAnswer, String?)?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
            return nil
        }
        var result: (JudgeAnswer, String?)?
        for await first in group {
            result = first
            break
        }
        group.cancelAll()
        return result.map { ($0.0, $0.1) } ?? (.unavailable(error: Task.isCancelled ? .aborted : .timeout), nil)
    }
}

/// The judge's proof step: fixed wording from its name, model, verdict and tool id only (no numbers, no remote text).
func judgeStepText(name: String, judged: JudgeVerdict, offered: Int, trigger: JudgeTrigger) -> String {
    let who = "\(name) (\(judged.model))"
    switch judged.verdict {
    case .approved: return "judge-approved: \(who) chose \(judged.toolId ?? "") from \(offered) offered (\(trigger.rawValue))"
    case .declined: return "judge-declined: \(who) chose none of the \(offered) offered (\(trigger.rawValue))"
    case .unavailable: return "judge-unavailable: \(who) gave no usable answer (\(trigger.rawValue)); deciding as without a judge"
    }
}

/// `metadata["judge"]` when a shortlist judge took part.
func judgeMetadata(_ proof: ResolutionProof) -> JudgeMetadata? {
    proof.judge.map { JudgeMetadata(name: $0.name, verdict: $0.verdict, toolId: $0.toolId) }
}

// MARK: - Execution -- the one boundary every dispatch path goes through

/// Arguments ready to run: their JSON form passed the tool's inputSchema.
struct PreparedCall: Sendable {
    let args: [String: any Sendable]
    let callDigest: String?
}

enum CallPreparation: Sendable {
    case ready(PreparedCall)
    case rejected([ValidationError])
}

/// Unwrap SCObjects, validate against the tool's inputSchema, and compute
/// the canonical call digest. Nothing executes unless this succeeds.
func prepareCall(_ imp: any ToolIMP, toolId: String, args: [String: any Sendable]) async -> CallPreparation {
    var unwrapped: [String: any Sendable] = [:]
    for (key, value) in args { unwrapped[key] = unwrapValue(value) }

    let json: [String: AnyCodableValue]
    do {
        json = try jsonObject(from: unwrapped)
    } catch {
        return .rejected([ValidationError(path: "", message: "arguments are not plain JSON: \(error)")])
    }

    let schema: ToolSchema
    if let loaded = imp.schema {
        schema = loaded
    } else {
        do {
            schema = try await imp.loadSchema()
        } catch {
            return .rejected([ValidationError(path: "", message: "could not load \(toolId)'s inputSchema: \(error)")])
        }
    }
    do {
        let validator = try JSONSchemaValidator(schema: .dict(schema.inputSchema.jsonValue))
        let errors = validator.validate(.dict(json))
        if !errors.isEmpty { return .rejected(errors) }
    } catch let error as InputSchemaError {
        return .rejected([ValidationError(path: "", message: "\(toolId) cannot be called: its \(error.message)")])
    } catch {
        return .rejected([ValidationError(path: "", message: "\(toolId) cannot be called: \(error)")])
    }

    do {
        _ = try canonicalJSON(.dict(json))
    } catch {
        return .rejected([ValidationError(path: "", message: "arguments are not plain JSON: \(error)")])
    }
    // An id that is not `<providerId>/<toolName>` has no digest; the call itself is fine.
    let digest = try? callDigest(toolId: toolId, arguments: json)
    return .ready(PreparedCall(args: unwrapped, callDigest: digest))
}

/// Record the validation result in the proof and finalize it.
func recordCall(_ proof: inout ResolutionProof, toolId: String, _ prepared: CallPreparation, elapsedMs: Double) {
    switch prepared {
    case .ready(let call):
        proof.ran = toolId
        proof.callDigest = call.callDigest
        proof.addStep(.validation, "Arguments valid for \(toolId); executing",
                      detail: ["callDigest": call.callDigest.map { .string($0) } ?? .null], elapsedMs: elapsedMs)
    case .rejected(let errors):
        proof.addStep(.validation, "Arguments rejected for \(toolId) (\(errors.count) error(s)); nothing executed",
                      detail: ["paths": .array(errors.map { .string($0.path) })], elapsedMs: elapsedMs)
    }
    proof.finalize()
}

/// The result returned when arguments fail validation. Nothing ran.
func invalidArgumentsResult(toolId: String, errors: [ValidationError], proof: ResolutionProof) -> ToolResult {
    ToolResult(
        content: AnyCodableValue.dict([
            "error": .string("Invalid arguments for \(toolId); the tool was not called."),
            "errors": .array(errors.map { .string($0.path.isEmpty ? $0.message : "\($0.path): \($0.message)") }),
        ]),
        isError: true,
        metadata: {
            var meta: [String: any Sendable] = [
                DispatchMetadataKey.outcome: DispatchOutcomeCode.invalidArguments.rawValue,
                DispatchMetadataKey.toolId: toolId,
                DispatchMetadataKey.validationErrors: errors,
                DispatchMetadataKey.proof: proof,
            ]
            if let judged = judgeMetadata(proof) { meta[DispatchMetadataKey.judge] = judged }
            return meta
        }()
    )
}

/// Annotate a tool's result with what ran and why.
func annotateExecuted(_ result: ToolResult, toolId: String, proof: ResolutionProof) -> ToolResult {
    var annotated = result
    var meta = result.metadata ?? [:]
    meta[DispatchMetadataKey.outcome] = DispatchOutcomeCode.resolved.rawValue
    meta[DispatchMetadataKey.toolId] = toolId
    meta[DispatchMetadataKey.callDigest] = proof.callDigest
    meta[DispatchMetadataKey.confidence] = proof.confidence
    meta[DispatchMetadataKey.tier] = proof.tier.rawValue
    meta[DispatchMetadataKey.proof] = proof
    if let judged = judgeMetadata(proof) { meta[DispatchMetadataKey.judge] = judged }
    annotated.metadata = meta
    return annotated
}

/// The result of a call whose task was cancelled before the tool started.
func abortedResult(toolId: String, proof: inout ResolutionProof) -> ToolResult {
    proof.ran = nil
    proof.addStep(.execution, "The caller cancelled before \(toolId) started; nothing executed")
    proof.finalize()
    return ToolResult(
        content: AnyCodableValue.dict(["error": .string("Dispatch of \(toolId) was cancelled; nothing was executed.")]),
        isError: true,
        metadata: {
            var meta: [String: any Sendable] = [
                DispatchMetadataKey.outcome: DispatchOutcomeCode.aborted.rawValue,
                DispatchMetadataKey.toolId: toolId,
                DispatchMetadataKey.proof: proof,
            ]
            if let judged = judgeMetadata(proof) { meta[DispatchMetadataKey.judge] = judged }
            return meta
        }()
    )
}

/// The result of a call whose tool left the dispatch index (its class was
/// unregistered, replaced or swizzled) before the tool started. Nothing ran.
func unregisteredResult(toolId: String, proof: inout ResolutionProof) -> ToolResult {
    proof.ran = nil
    proof.addStep(.execution, "\(toolId) left the tool registry (its class was unregistered or replaced) before it started; nothing executed")
    proof.finalize()
    return ToolResult(
        content: AnyCodableValue.dict(["error": .string("\(toolId) was unregistered or replaced while the call was being prepared; nothing was executed.")]),
        isError: true,
        metadata: [
            DispatchMetadataKey.outcome: DispatchOutcomeCode.unresolved.rawValue,
            DispatchMetadataKey.toolId: toolId,
            DispatchMetadataKey.proof: proof,
        ]
    )
}

/// The result of an intent that did not resolve to one tool. Nothing ran.
func notExecutedResult(_ resolution: Resolution) -> ToolResult {
    let options = resolution.refinement?.nearMatches.map(\.toolId) ?? []
    var content: [String: AnyCodableValue] = [
        "error": .string("\(resolution.reason ?? "No tool was chosen for \"\(resolution.intent)\""). Nothing was executed."),
        "outcome": .string(resolution.outcome.rawValue),
        "intent": .string(resolution.intent),
        "candidates": .array(resolution.candidates.prefix(5).map {
            .dict(["toolId": .string($0.toolId), "score": .double($0.score), "tier": .string($0.tier.rawValue)])
        }),
    ]
    if !options.isEmpty { content["options"] = .array(options.map { .string($0) }) }
    var metadata: [String: any Sendable] = [
        DispatchMetadataKey.outcome: resolution.outcome.rawValue,
        DispatchMetadataKey.tier: resolution.tier.rawValue,
        DispatchMetadataKey.proof: resolution.proof,
    ]
    if let judged = judgeMetadata(resolution.proof) { metadata[DispatchMetadataKey.judge] = judged }
    if let refinement = resolution.refinement { metadata[DispatchMetadataKey.refinement] = refinement }
    if let retry = resolution.retryAfterMs { metadata[DispatchMetadataKey.retryAfterMs] = retry }
    return ToolResult(content: AnyCodableValue.dict(content), isError: true, metadata: metadata)
}

extension DispatchContext {

    /// The proof of a dispatch by exact tool id (before execution).
    func exactIdProof(_ toolId: String, tool: RegisteredTool, options: DispatchByIdOptions) -> ResolutionProof {
        var proof = newProof(intent: nil)
        let verdict = evaluateDispatchPolicy(
            PolicyInput(mode: .id, toolId: toolId, annotations: tool.imp.annotations, source: .exactId,
                        score: 1, similarity: nil, llmApproved: false, pins: []),
            options: policyOptions
        )
        proof.resolutionDigest = options.resolutionDigest
        proof.outcome = .resolved
        proof.decision = .exactId
        proof.tier = .exact
        proof.chosen = toolId
        proof.confidence = 1
        proof.candidates = [ProofCandidate(toolId: toolId, selector: tool.selectors.first ?? "", score: 1,
                                           similarity: nil, tier: .exact, source: .exactId)]
        proof.addStep(.exactId, verdict.reason, detail: ["toolId": .string(toolId)])
        return proof
    }

    /// Execute exactly the named tool. O(1) lookup, no embedding, no
    /// resolution. Arguments are validated against the tool's inputSchema
    /// first; invalid arguments, an unknown id or an ambiguous id return an
    /// `isError` result and run nothing. Errors the tool itself throws
    /// propagate.
    public func dispatchById(
        _ toolId: String,
        args: [String: any Sendable] = [:],
        options: DispatchByIdOptions = DispatchByIdOptions()
    ) async throws -> ToolResult {
        guard let tool = getTool(toolId) else {
            var proof = newProof(intent: nil)
            proof.resolutionDigest = options.resolutionDigest
            proof.decision = .unknownTool
            let ambiguous = isAmbiguousToolId(toolId)
            proof.addStep(.exactId, ambiguous ? "\(toolId) is claimed by more than one tool" : "\(toolId) is not a registered tool")
            proof.finalize()
            let message = ambiguous
                ? "Tool id \"\(toolId)\" is claimed by more than one registered tool; nothing was executed."
                : "Unknown tool \"\(toolId)\"; nothing was executed. Tool ids have the form \"<providerId>/<toolName>\"."
            return ToolResult(
                content: AnyCodableValue.dict(["error": .string(message)]),
                isError: true,
                metadata: [
                    DispatchMetadataKey.outcome: DispatchOutcomeCode.unresolved.rawValue,
                    DispatchMetadataKey.toolId: toolId,
                    DispatchMetadataKey.proof: proof,
                ]
            )
        }

        var proof = exactIdProof(toolId, tool: tool, options: options)
        if Task.isCancelled {
            let aborted = abortedResult(toolId: toolId, proof: &proof)
            try await decisionLog?.record(kind: .dispatchById, proof: proof, execution: .aborted, principal: options.principal, toolId: toolId)
            return aborted
        }
        let clock = ProofTimer()
        let prepared = await prepareCall(tool.imp, toolId: toolId, args: args)
        recordCall(&proof, toolId: toolId, prepared, elapsedMs: clock.milliseconds())
        guard case .ready(let call) = prepared else {
            try await decisionLog?.record(kind: .dispatchById, proof: proof, execution: .invalidArguments, principal: options.principal, toolId: toolId)
            if case .rejected(let errors) = prepared { return invalidArgumentsResult(toolId: toolId, errors: errors, proof: proof) }
            return invalidArgumentsResult(toolId: toolId, errors: [], proof: proof)
        }
        // Recorded before the tool runs: nothing runs unrecorded. The log
        // write suspends, so the registry is checked after it, with no
        // suspension before the call starts.
        try await decisionLog?.record(kind: .dispatchById, proof: proof, execution: .ran, principal: options.principal, toolId: toolId)
        // Once unregisterClass/registerClass returns, the old tool never starts.
        guard isRegistered(tool.imp) else { return unregisteredResult(toolId: toolId, proof: &proof) }
        let result = try await tool.imp.execute(args: call.args)
        return annotateExecuted(result, toolId: toolId, proof: proof)
    }

    /// Resolve an intent and execute exactly the chosen tool, through the
    /// same validation boundary as `dispatchById`. When resolution does not
    /// settle on one tool, nothing runs and the result is an `isError`
    /// result carrying the candidates (`metadata["outcome"]`).
    public func dispatch(
        _ intent: String,
        args: [String: any Sendable]? = nil,
        options: DispatchOptions = DispatchOptions()
    ) async throws -> ToolResult {
        try await dispatchIntent(intent, args: args, frame: DispatchFrame(principal: options.principal))
    }

    func dispatchIntent(_ intent: String, args: [String: any Sendable]?, frame: DispatchFrame) async throws -> ToolResult {
        let r = try await resolveInternal(intent, run: ResolveRun(
            learn: true,
            args: args,
            principal: frame.principal,
            allowDecomposition: true,
            depth: frame.depth,
            ancestors: frame.ancestors
        ))
        let resolution = r.resolution

        if let subIntents = r.decomposition {
            // Each sub-intent goes through this same pipeline (and policy), one level deeper.
            var result = try await runDecomposition(resolution.intent, subIntents: subIntents, frame: frame)
            var meta = result.metadata ?? [:]
            meta[DispatchMetadataKey.outcome] = DispatchOutcomeCode.resolved.rawValue
            meta[DispatchMetadataKey.tier] = resolution.tier.rawValue
            meta[DispatchMetadataKey.proof] = resolution.proof
            result.metadata = meta
            return result
        }

        guard resolution.outcome == .resolved, let imp = r.imp, let toolId = resolution.chosen else {
            await observer?.record(.refined(intent: resolution.intent, tier: resolution.tier))
            try await decisionLog?.record(kind: .dispatch, proof: resolution.proof, execution: .none, principal: frame.principal)
            return notExecutedResult(resolution)
        }

        var proof = resolution.proof
        if Task.isCancelled {
            let aborted = abortedResult(toolId: toolId, proof: &proof)
            try await decisionLog?.record(kind: .dispatch, proof: proof, execution: .aborted, principal: frame.principal)
            return aborted
        }
        let clock = ProofTimer()
        let prepared = await prepareCall(imp, toolId: toolId, args: args ?? [:])
        recordCall(&proof, toolId: toolId, prepared, elapsedMs: clock.milliseconds())
        guard case .ready(let call) = prepared else {
            try await decisionLog?.record(kind: .dispatch, proof: proof, execution: .invalidArguments, principal: frame.principal)
            if case .rejected(let errors) = prepared { return invalidArgumentsResult(toolId: toolId, errors: errors, proof: proof) }
            return invalidArgumentsResult(toolId: toolId, errors: [], proof: proof)
        }
        // Resolution and validation can suspend; the registry may have
        // changed since the tool was chosen.
        guard isRegistered(imp) else { return unregisteredResult(toolId: toolId, proof: &proof) }
        // Recorded before the tool runs: nothing runs unrecorded.
        try await decisionLog?.record(kind: .dispatch, proof: proof, execution: .ran, principal: frame.principal)

        var result = annotateExecuted(try await imp.execute(args: call.args), toolId: toolId, proof: proof)
        await observer?.record(.accepted(toolName: toolId, tier: resolution.tier, confidence: resolution.confidence ?? 0))

        // Annotate ambiguous results so callers know another tool was close.
        if resolution.candidates.count > 1, (resolution.confidence ?? 0) <= ambiguousConfidence {
            var meta = result.metadata ?? [:]
            meta["ambiguous"] = true
            meta["candidateCount"] = resolution.candidates.count
            let top: [[String: any Sendable]] = resolution.candidates.prefix(3).map {
                ["toolId": $0.toolId, "confidence": $0.score]
            }
            meta["topCandidates"] = top
            result.metadata = meta
        }
        return result
    }

    /// Run a decomposition's sub-intents in order, one level deeper, within
    /// the request's sub-dispatch budget.
    func runDecomposition(_ intent: String, subIntents: [String], frame: DispatchFrame) async throws -> ToolResult {
        frame.budget.start(limit: dispatchConfig.maxSubDispatches)
        let child = DispatchFrame(
            principal: frame.principal,
            depth: frame.depth + 1,
            ancestors: frame.ancestors + [intentKey(intent)],
            budget: frame.budget
        )
        var results: [[String: any Sendable]] = []
        var hasErrors = false
        for sub in subIntents {
            let subResult: ToolResult
            if frame.budget.take() {
                subResult = try await dispatchIntent(sub, args: nil, frame: child)
            } else {
                subResult = ToolResult(
                    content: AnyCodableValue.dict(["error": .string("Not dispatched: the sub-dispatch limit (\(frame.budget.limit)) for this request was reached.")]),
                    isError: true,
                    metadata: [DispatchMetadataKey.outcome: DispatchOutcomeCode.notDispatched.rawValue]
                )
            }
            hasErrors = hasErrors || subResult.isError
            var entry: [String: any Sendable] = ["intent": sub, "isError": subResult.isError]
            if let content = subResult.content { entry["content"] = content }
            if let metadata = subResult.metadata { entry["metadata"] = metadata }
            results.append(entry)
        }
        let content: [String: any Sendable] = [
            "decomposed": true,
            "original": intent,
            "strategy": "sequential",
            "results": results,
        ]
        return ToolResult(
            content: content,
            isError: hasErrors,
            metadata: ["decomposed": true, "subIntentCount": subIntents.count, "strategy": "sequential"]
        )
    }
}

/// Per-request dispatch state: each top-level dispatch gets its own frame,
/// so concurrent dispatches never share depth or budget.
struct DispatchFrame: Sendable {
    var principal: String?
    var depth: Int = 0
    var ancestors: [String] = []
    /// Sub-dispatches left for the whole request (shared by the tree).
    var budget = SubDispatchBudget()
}

/// The sub-dispatch budget of one request, shared by its decomposition tree.
final class SubDispatchBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = Int.max
    private(set) var limit = Int.max

    /// Set the limit the first time a decomposition runs.
    func start(limit newLimit: Int) {
        lock.withLock {
            if limit == Int.max {
                limit = newLimit
                remaining = newLimit
            }
        }
    }

    /// Take one sub-dispatch; false when none is left.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

// MARK: - Free-function entry points

/// Resolve an intent (see `DispatchContext.resolve(_:options:)`). Never executes.
public func resolveIntent(
    context: DispatchContext,
    intent: String,
    options: ResolveOptions = ResolveOptions()
) async throws -> Resolution {
    try await context.resolve(intent, options: options)
}

/// Execute exactly the named tool (see `DispatchContext.dispatchById`).
public func dispatchById(
    context: DispatchContext,
    toolId: String,
    args: [String: any Sendable] = [:],
    options: DispatchByIdOptions = DispatchByIdOptions()
) async throws -> ToolResult {
    try await context.dispatchById(toolId, args: args, options: options)
}

/// toolkit_dispatch -- resolve(intent) -> policy -> execute exactly the
/// chosen tool. When resolution does not settle on one tool, nothing runs.
public func toolkitDispatch(
    context: DispatchContext,
    intent: String,
    args: [String: any Sendable]? = nil,
    options: DispatchOptions = DispatchOptions()
) async throws -> ToolResult {
    try await context.dispatch(intent, args: args, options: options)
}

// MARK: - Streaming

/// smallchat_dispatchStream -- async stream variant of toolkit_dispatch.
///
/// Yields DispatchEvent objects for real-time UI feedback:
///   1. `resolving` -- immediately
///   2. `toolStart` -- once a tool is resolved and its arguments validated
///   3. `chunk` / `inferenceDelta` -- incremental content from the tool
///   4. `done` -- the final result (an `isError` result, with nothing run,
///      when resolution did not settle on one tool)
///   5. `error` -- invalid arguments, or the tool failed
public func smallchatDispatchStream(
    context: DispatchContext,
    intent: String,
    args: [String: any Sendable]? = nil,
    options: DispatchOptions = DispatchOptions()
) -> AsyncThrowingStream<DispatchEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            continuation.yield(.resolving(intent: intent))
            let frame = DispatchFrame(principal: options.principal)
            let r: InternalResolution
            do {
                r = try await context.resolveInternal(intent, run: ResolveRun(
                    learn: true, args: args, principal: frame.principal, allowDecomposition: true, depth: 0, ancestors: []
                ))
            } catch {
                continuation.yield(.error(message: String(describing: error), metadata: streamErrorMetadata(error)))
                continuation.finish()
                return
            }

            do {
                if let subIntents = r.decomposition {
                    var result = try await context.runDecomposition(r.resolution.intent, subIntents: subIntents, frame: frame)
                    var meta = result.metadata ?? [:]
                    meta[DispatchMetadataKey.outcome] = DispatchOutcomeCode.resolved.rawValue
                    meta[DispatchMetadataKey.proof] = r.resolution.proof
                    result.metadata = meta
                    continuation.yield(.done(result: result))
                    continuation.finish()
                    return
                }
                guard r.resolution.outcome == .resolved, let imp = r.imp, let toolId = r.resolution.chosen else {
                    continuation.yield(.done(result: notExecutedResult(r.resolution)))
                    continuation.finish()
                    return
                }
                let selector = r.resolution.candidates.first { $0.toolId == toolId }?.selector ?? ""
                try await validateAndStream(
                    context: context, imp: imp, toolId: toolId, args: args ?? [:], proof: r.resolution.proof,
                    confidence: r.resolution.confidence ?? 0, selector: selector, continuation: continuation
                )
            } catch {
                continuation.yield(.error(message: String(describing: error), metadata: nil))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Streaming variant of `dispatchById`: executes exactly the named tool.
public func smallchatDispatchStreamById(
    context: DispatchContext,
    toolId: String,
    args: [String: any Sendable] = [:],
    options: DispatchByIdOptions = DispatchByIdOptions()
) -> AsyncThrowingStream<DispatchEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                guard let tool = await context.getTool(toolId) else {
                    continuation.yield(.done(result: try await context.dispatchById(toolId, args: args, options: options)))
                    continuation.finish()
                    return
                }
                let proof = await context.exactIdProof(toolId, tool: tool, options: options)
                try await validateAndStream(
                    context: context, imp: tool.imp, toolId: toolId, args: args, proof: proof,
                    confidence: 1, selector: tool.selectors.first ?? "", continuation: continuation
                )
            } catch {
                continuation.yield(.error(message: String(describing: error), metadata: nil))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func streamErrorMetadata(_ error: Error) -> [String: AnyCodableValue]? {
    if let err = error as? IntentValidationError {
        return ["validationError": .bool(true), "reason": .string(err.reason)]
    }
    return nil
}

/// Validate, then execute a tool and stream its result at the finest
/// granularity the IMP supports (inference deltas, chunks, single shot).
/// A tool that left the registry while the call was prepared does not
/// start; the stream checks from outside the context's actor, so a
/// registry change landing in that last hop is not seen.
private func validateAndStream(
    context: DispatchContext,
    imp: any ToolIMP,
    toolId: String,
    args: [String: any Sendable],
    proof initial: ResolutionProof,
    confidence: Double,
    selector: String,
    continuation: AsyncThrowingStream<DispatchEvent, Error>.Continuation
) async throws {
    var proof = initial
    if Task.isCancelled {
        continuation.yield(.done(result: abortedResult(toolId: toolId, proof: &proof)))
        return
    }
    let clock = ProofTimer()
    let prepared = await prepareCall(imp, toolId: toolId, args: args)
    recordCall(&proof, toolId: toolId, prepared, elapsedMs: clock.milliseconds())
    guard case .ready(let call) = prepared else {
        var errors: [ValidationError] = []
        if case .rejected(let rejected) = prepared { errors = rejected }
        continuation.yield(.error(
            message: "Invalid arguments for \(toolId); the tool was not called: \(errors.map(\.message).joined(separator: "; "))",
            metadata: ["toolId": .string(toolId), "validationErrors": .array(errors.map { .string($0.message) })]
        ))
        return
    }
    guard await context.isRegistered(imp) else {
        continuation.yield(.done(result: unregisteredResult(toolId: toolId, proof: &proof)))
        return
    }

    continuation.yield(.toolStart(toolName: imp.toolName, providerId: imp.providerId, confidence: confidence, selector: selector))

    // Tier 1: progressive inference (token-level)
    if let inferenceImp = imp as? any InferenceIMP {
        var tokenIndex = 0
        var parts: [String] = []
        for try await delta in inferenceImp.executeInference(args: call.args) {
            continuation.yield(.inferenceDelta(delta: delta, tokenIndex: tokenIndex))
            parts.append(delta.text)
            tokenIndex += 1
        }
        let assembled = parts.joined()
        continuation.yield(.chunk(content: .string(assembled), index: 0))
        continuation.yield(.done(result: annotateExecuted(ToolResult(content: assembled), toolId: toolId, proof: proof)))
        return
    }

    // Tier 2: chunk-level streaming
    if let streamableImp = imp as? any StreamableIMP {
        var index = 0
        var lastResult: ToolResult?
        for try await chunk in streamableImp.executeStream(args: call.args) {
            if let content = chunk.content {
                continuation.yield(.chunk(content: anyCodableFromSendable(content), index: index))
            }
            index += 1
            lastResult = chunk
        }
        continuation.yield(.done(result: annotateExecuted(lastResult ?? ToolResult(content: nil), toolId: toolId, proof: proof)))
        return
    }

    // Tier 3: single shot
    let result = try await imp.execute(args: call.args)
    if let content = result.content {
        continuation.yield(.chunk(content: anyCodableFromSendable(content), index: 0))
    }
    continuation.yield(.done(result: annotateExecuted(result, toolId: toolId, proof: proof)))
}

// MARK: - Helpers

/// Best-effort conversion from `any Sendable` to `AnyCodableValue`.
private func anyCodableFromSendable(_ value: any Sendable) -> AnyCodableValue {
    if let converted = try? jsonValue(from: value) { return converted }
    return .string(String(describing: value))
}
