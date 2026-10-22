import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SmallChatRuntime
import SmallChatCore
import SmallChatEmbedding

// MARK: - A three-tool runtime (github/get_issue 0.90, gitlab/get_issue 0.88, github/list_issues 0.70)

private let tools = [("github/get_issue", 0.9), ("gitlab/get_issue", 0.88), ("github/list_issues", 0.7)]
private let intent = "look up issue"

private struct AxisEmbedder: Embedder {
    let dimensions: Int
    func embed(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[text == intent ? 0 : dimensions - 1] = 1
        return v
    }
}

private final class IssueIMP: ToolIMP, @unchecked Sendable {
    let providerId: String
    let toolName: String
    let transportType: TransportType = .local
    let schema: ToolSchema?
    init(_ providerId: String, _ toolName: String) {
        self.providerId = providerId
        self.toolName = toolName
        schema = ToolSchema(name: toolName, description: intent, inputSchema: JSONSchemaType(type: "object"))
    }
    func loadSchema() async throws -> ToolSchema { schema! }
    func execute(args: [String: any Sendable]) async throws -> ToolResult { ToolResult(content: "ran \(providerId)/\(toolName)") }
}

final class ChoosingJudge: ShortlistJudge, @unchecked Sendable {
    let name = "stub"
    let model = "stub-1"
    let timeoutMs: Int?
    let choice: String?
    private let lock = NSLock()
    private var seen: [JudgeRequest] = []
    private var grades: [JudgeFeedback] = []
    var throwOnFeedback = false
    init(choice: String?, timeoutMs: Int? = nil) {
        self.choice = choice
        self.timeoutMs = timeoutMs
    }
    var requests: [JudgeRequest] { lock.withLock { seen } }
    var feedbackReceived: [JudgeFeedback] { lock.withLock { grades } }
    func judge(_ request: JudgeRequest) async -> JudgeAnswer {
        lock.withLock { seen.append(request) }
        return .answered(choice: choice, probability: 0.9, confidence: 0.8)
    }
    func feedback(_ grade: JudgeFeedback) async throws {
        if throwOnFeedback { throw SystemOneJudgeError(message: "store is read-only") }
        lock.withLock { grades.append(grade) }
    }
}

private func issueRuntime(judge: (any ShortlistJudge)?, judgeContext: (any JudgeContextProvider)? = nil, decisionLog: DecisionLog? = nil) async throws -> ToolRuntime {
    let dims = tools.count + 2
    let runtime = ToolRuntime(vectorIndex: MemoryVectorIndex(), embedder: AxisEmbedder(dimensions: dims),
                              options: RuntimeOptions(judge: judge, judgeContext: judgeContext, decisionLog: decisionLog, artifactHash: String(repeating: "a", count: 64)))
    var classes: [String: ToolClass] = [:]
    for (i, (id, score)) in tools.enumerated() {
        let (providerId, toolName) = try parseToolId(id)
        var vector = [Float](repeating: 0, count: dims)
        vector[0] = Float(score)
        vector[i + 1] = Float((1 - score * score).squareRoot())
        let selector = try await runtime.selectorTable.register(embedding: vector, canonical: "\(providerId).\(toolName)")
        if classes[providerId] == nil { classes[providerId] = ToolClass(name: providerId) }
        classes[providerId]!.addMethod(selector, imp: IssueIMP(providerId, toolName))
    }
    for name in ["github", "gitlab"] { try await runtime.registerClass(classes[name]!) }
    return runtime
}

private let sampleContext = JudgeContext(sessionId: "s1", truth: [JudgeTruthEntry(id: "tb1", type: "TB", status: "active", text: "gitlab is the tracker now", grade: .asserted)])

private struct FixedContext: JudgeContextProvider {
    let name = "steno"
    let answer: JudgeContext?
    let delayMs: Int
    func context(intent: String, principal: String?) async throws -> JudgeContext? {
        if delayMs > 0 { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
        return answer
    }
}

// MARK: - Tests

@Suite("The shortlist judge in dispatch")
struct JudgeDispatchTests {
    @Test("a near-tie is judged: the approved runner-up is chosen, judge-approved, with the record and step; nothing is cached")
    func approvedRunnerUp() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        let runtime = try await issueRuntime(judge: judge)
        let r = try await runtime.resolve(intent)
        #expect(r.outcome == .resolved)
        #expect(r.chosen == "gitlab/get_issue")
        #expect(r.proof.decision == .judgeApproved)
        #expect(r.proof.judge?.verdict == .approved)
        #expect(r.proof.judge?.name == "stub")
        #expect(r.proof.steps.contains { $0.stage == .judge && $0.decision == "judge-approved: stub (stub-1) chose gitlab/get_issue from 2 offered (ambiguous)" })
        #expect(judge.requests.first?.candidates.map(\.toolId) == ["github/get_issue", "gitlab/get_issue"])
        // A dispatch carries metadata.judge and re-asks (never cached)
        let result = try await runtime.dispatch(intent, args: [:])
        let meta = try #require(result.metadata?[DispatchMetadataKey.judge] as? JudgeMetadata)
        #expect(meta == JudgeMetadata(name: "stub", verdict: .approved, toolId: "gitlab/get_issue"))
        #expect(judge.requests.count == 2)
    }

    @Test("a decline is needs-disambiguation with judge-declined; unavailable decides as without a judge, but is recorded")
    func declinedAndUnavailable() async throws {
        let declining = ChoosingJudge(choice: nil)
        let declined = try await issueRuntime(judge: declining).resolve(intent)
        #expect(declined.outcome == .needsDisambiguation)
        #expect(declined.proof.decision == .judgeDeclined)
        #expect(declined.proof.judge?.reason == "abstained")

        struct Down: ShortlistJudge {
            let name = "down"
            let model = "d-1"
            func judge(_ request: JudgeRequest) async -> JudgeAnswer { .unavailable(error: .network) }
        }
        let unavailable = try await issueRuntime(judge: Down()).resolve(intent)
        #expect(unavailable.outcome == .resolved)
        #expect(unavailable.chosen == "github/get_issue")
        #expect(unavailable.proof.decision == .ranked)
        #expect(unavailable.proof.judge?.verdict == .unavailable)
        #expect(unavailable.proof.judge?.reason == "NETWORK")
        let plain = try await issueRuntime(judge: nil).resolve(intent)
        #expect(plain.proof.judge == nil)
        #expect(plain.proof.proofDigest != unavailable.proof.proofDigest)
    }

    @Test("a judge that never answers is held to its timeout")
    func timeout() async throws {
        struct Hangs: ShortlistJudge {
            let name = "hangs"
            let model = "h-1"
            var timeoutMs: Int? { 50 }
            func judge(_ request: JudgeRequest) async -> JudgeAnswer {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .answered(choice: "gitlab/get_issue", probability: 1, confidence: 1)
            }
        }
        let started = Date()
        let r = try await issueRuntime(judge: Hangs()).resolve(intent)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(r.proof.judge?.reason == "TIMEOUT")
        #expect(r.chosen == "github/get_issue")
    }

    @Test("a judge whose settings are out of range is not consulted, and the error is kept")
    func badSettings() async throws {
        struct Bad: ShortlistJudge {
            let name = "bad"
            let model = "b-1"
            var margin: Double? { 2 }
            func judge(_ request: JudgeRequest) async -> JudgeAnswer { .answered(choice: "gitlab/get_issue", probability: 1, confidence: 1) }
        }
        let runtime = try await issueRuntime(judge: Bad())
        #expect(await runtime.context.judge == nil)
        #expect(await runtime.context.judgeConfigurationError?.contains("margin") == true)
        #expect(try await runtime.resolve(intent).proof.judge == nil)
    }

    @Test("ResolveOptions.judge: .off skips the runtime's judge; .recorded replays without calling it")
    func overrides() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        let runtime = try await issueRuntime(judge: judge)
        let first = try await runtime.resolve(intent)
        let none = try await runtime.resolve(intent, options: ResolveOptions(judge: .off))
        #expect(none.proof.judge == nil && none.chosen == "github/get_issue")
        let replayed = try await runtime.resolve(intent, options: ResolveOptions(judge: .recorded(RecordedJudgeVerdict(first.proof.judge!))))
        #expect(replayed.chosen == "gitlab/get_issue")
        #expect(replayed.proof.proofDigest == first.proof.proofDigest)
        #expect(judge.requests.count == 1)
        // A verdict without a name replays as `recorded (unknown)`
        let anonymous = try await runtime.resolve(intent, options: ResolveOptions(judge: .recorded(RecordedJudgeVerdict(verdict: .approved, toolId: "gitlab/get_issue"))))
        #expect(anonymous.proof.judge?.name == "recorded")
        #expect(anonymous.proof.judge?.model == "unknown")
    }
}

@Suite("Judge context and grading")
struct JudgeContextTests {
    @Test("the provider is asked once, its context rides with the request, and the step names it (never the context)")
    func contextOffered() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        let r = try await issueRuntime(judge: judge, judgeContext: FixedContext(answer: sampleContext, delayMs: 0)).resolve(intent)
        #expect(judge.requests.first?.context == sampleContext)
        let step = try #require(r.proof.steps.first { $0.stage == .judge })
        #expect(step.detail?["context"] == .string("steno"))
        #expect(!(try canonicalJSON(r.proof.jsonValue)).contains("gitlab is the tracker now"))
        let bare = ChoosingJudge(choice: "gitlab/get_issue")
        let plain = try await issueRuntime(judge: bare).resolve(intent)
        #expect(bare.requests.first?.context == nil)
        #expect(plain.proof.steps.first { $0.stage == .judge }?.detail?["context"] == nil)
    }

    @Test("a provider that answers nil or is slow leaves the judge with the intent alone")
    func contextMissing() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        _ = try await issueRuntime(judge: judge, judgeContext: FixedContext(answer: nil, delayMs: 0)).resolve(intent)
        #expect(judge.requests.first?.context == nil)
        let slowJudge = ChoosingJudge(choice: "gitlab/get_issue", timeoutMs: 40)
        let r = try await issueRuntime(judge: slowJudge, judgeContext: FixedContext(answer: sampleContext, delayMs: 2000)).resolve(intent)
        #expect(r.proof.judge?.verdict == .unavailable)
        #expect(slowJudge.requests.isEmpty)
    }

    @Test("gradeJudgement: a reward and a correction are logged as judge-feedback lines and told to the judge; replay skips them")
    func grading() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        let log = try DecisionLog()
        let runtime = try await issueRuntime(judge: judge, decisionLog: log)
        let r = try await runtime.resolve(intent)
        let rewarded = try await runtime.gradeJudgement(r, correct: true, reason: "the user confirmed")
        #expect(rewarded.logged && rewarded.judgeInformed && rewarded.judgeError == nil)
        #expect(rewarded.feedback.outcome == .rewarded && rewarded.feedback.correctToolId == "gitlab/get_issue")
        let corrected = try await runtime.gradeJudgement(r, correct: false, correctToolId: "github/get_issue", reason: "wrong tracker")
        #expect(corrected.feedback.outcome == .corrected && corrected.feedback.correctToolId == "github/get_issue")
        #expect(judge.feedbackReceived.map(\.outcome) == [.rewarded, .corrected])
        let lines = await log.lines()
        let verified = verifyDecisionLog(lines.joined(separator: "\n") + "\n")
        #expect(verified.ok, "\(verified.error?.description ?? "")")
        #expect(verified.records.map(\.kind) == [.resolve, .judgeFeedback, .judgeFeedback])
        #expect(verified.records[2].feedback == DecisionFeedback(outcome: .corrected, correctToolId: "github/get_issue", reason: "wrong tracker"))
        #expect(verified.records[2].judge?.name == "stub")
        let report = try await runtime.replayDecisionLog(verified.records)
        #expect(report.entries.map(\.status) == [.reproduced, .skipped, .skipped])
        #expect(report.entries[0].proofIdentical == true)
        #expect(judge.requests.count == 1, "replay never calls the judge")
        // Refusals
        var noJudge = r.proof
        noJudge.judge = nil
        let unjudged = Resolution(outcome: r.outcome, intent: r.intent, tier: r.tier, chosen: r.chosen, confidence: r.confidence, candidates: r.candidates, proof: noJudge, reason: nil, refinement: nil, retryAfterMs: nil)
        await #expect(throws: JudgeSettingsError.self) { try await runtime.gradeJudgement(unjudged, correct: true) }
        await #expect(throws: JudgeSettingsError.self) { try await runtime.gradeJudgement(r, correct: false, correctToolId: "gitlab/get_issue") }
        judge.throwOnFeedback = true
        let failed = try await runtime.gradeJudgement(r, correct: true)
        #expect(!failed.judgeInformed && failed.judgeError?.contains("read-only") == true)
    }
}

@Suite("The decision log")
struct DecisionLogTests {
    @Test("records resolve, dispatch and dispatch-by-id lines before anything runs, hash-chained, and a file continues its chain")
    func chain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smallchat-log-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("decisions.jsonl").path
        do {
            let log = try DecisionLog(path: path)
            let runtime = try await issueRuntime(judge: nil, decisionLog: log)
            _ = try await runtime.resolve(intent)
            _ = try await runtime.dispatch(intent, args: [:])
            _ = try await runtime.dispatchById("github/list_issues", args: [:])
            _ = try await runtime.dispatch("nothing like it", args: [:])
            await log.close()
        }
        let records = try readDecisionLog(path: path)
        #expect(records.map(\.kind) == [.resolve, .dispatch, .dispatchById, .dispatch])
        #expect(records.map(\.execution) == [.none, .ran, .ran, .none])
        #expect(records[1].callDigest != nil && records[0].callDigest == nil)
        #expect(records[2].toolId == "github/list_issues" && records[2].intentDigest == nil)
        #expect(records.map(\.seq) == [1, 2, 3, 4])
        #expect(records[1].prevHash == records[0].hash)
        // Appending continues the chain
        let again = try DecisionLog(path: path)
        let head = await again.head
        #expect(head.seq == 4 && head.hash == records[3].hash)
        await again.close()
        // A tampered line breaks it
        var text = try String(contentsOfFile: path, encoding: .utf8)
        text = text.replacingOccurrences(of: "github/list_issues", with: "github/get_issue")
        let broken = verifyDecisionLog(text)
        #expect(!broken.ok && broken.error?.line == 3)
        #expect(!verifyDecisionLog(String(text.dropLast())).ok, "no trailing newline")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("a log @smallchat/core wrote verifies here, hash for hash, and replays against the same tools")
    func typescriptLog() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/decision-log/typescript.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let verified = verifyDecisionLog(text)
        #expect(verified.ok, "\(verified.error?.description ?? "")")
        #expect(verified.records.map(\.kind) == [.resolve, .judgeFeedback, .dispatchById, .resolve])
        for record in verified.records {
            #expect(try decisionRecordHash(record.bodyJSON) == record.hash, "seq \(record.seq)")
            if let intent = record.intent { #expect(try intentDigest(intent) == record.intentDigest) }
        }
        #expect(verified.records[0].judge?.verdict == .approved)
        #expect(verified.records[1].feedback?.outcome == .corrected)
        // Replayed against the same three tools: the judged line reproduces from its recorded verdict
        let runtime = try await issueRuntime(judge: ChoosingJudge(choice: nil))
        let report = try await runtime.replayDecisionLog(verified.records)
        #expect(report.entries.map(\.status) == [.reproduced, .skipped, .reproduced, .reproduced])
        #expect(report.entries[0].replayed?.toolId == "gitlab/get_issue")
    }
}

@Suite("Explain")
struct ExplainTests {
    @Test("explain(intent) never asks the judge, says whether a live dispatch would, and formats")
    func explainIntent() async throws {
        let judge = ChoosingJudge(choice: "gitlab/get_issue")
        let runtime = try await issueRuntime(judge: judge)
        let e = try await runtime.explain(intent)
        #expect(judge.requests.isEmpty)
        #expect(e.judgeConfigured?.name == "stub")
        #expect(e.judgeConsulted == nil)
        #expect(e.judgeWouldAsk == .some(JudgeWouldAsk(trigger: .ambiguous, offered: ["github/get_issue", "gitlab/get_issue"])))
        #expect(e.candidates.map(\.rank) == [1, 2, 3])
        #expect(e.candidates[0].verdict?.allow == true)
        let text = formatExplanation(e)
        #expect(text.contains("a live dispatch would ask it (ambiguous) to choose among github/get_issue, gitlab/get_issue"))
        #expect(text.contains("Proof digest: \(e.proofDigest)"))
        // explain(resolution) reports the verdict
        let r = try await runtime.resolve(intent)
        let explained = await runtime.explain(r)
        #expect(explained.judgeConsulted?.verdict == .approved)
        #expect(formatExplanation(explained).contains("Judge said:  approved gitlab/get_issue"))
    }
}
