import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SmallChatCore
import SmallChatRuntime
import SmallChatEmbedding

/// spec/judge/vectors.json (smallchat.judge.v1): the trigger rule, resolve
/// with a stub judge (whether it is asked, what it is offered, the outcome,
/// decision, tier and choice, and what the proof records), replay with a
/// recorded verdict in the judge's place (the runtime's own judge is never
/// called), and the System One wire's responses read by the judge client.
@Suite("Conformance: shortlist judge (spec/judge)")
struct JudgeVectorTests {
    static let spec = try! SpecFixtures.json("judge/vectors.json")
    static let defaults = spec["defaults"]!

    @Test("the vectors are smallchat.judge.v1")
    func version() {
        #expect(Self.spec["version"]?.stringValue == "smallchat.judge.v1")
    }

    @Test("trigger", arguments: JudgeVectorTests.spec["trigger"]!.arrayValue)
    func trigger(_ c: AnyCodableValue) throws {
        let tier = try #require(DispatchTier(rawValue: c["tier"]!.stringValue!))
        let margin = c["margin"]?.doubleValue ?? Self.defaults["margin"]!.doubleValue!
        let got = judgeTrigger(tier: tier, bestScore: c["best"]!.doubleValue!, runnerUpScore: c["runnerUp"]?.doubleValue, margin: margin)
        #expect(got?.rawValue == c["expect"]?.stringValue, "\(c["name"]?.stringValue ?? "?")")
    }

    /// A judge that answers the case's answer and remembers what it was asked.
    final class StubJudge: ShortlistJudge, @unchecked Sendable {
        let name: String
        let model: String
        let margin: Double?
        let maxCandidates: Int?
        let acceptThreshold: Double?
        let answer: AnyCodableValue?
        let lock = NSLock()
        var requests: [JudgeRequest] = []
        init(name: String, model: String, margin: Double?, maxCandidates: Int?, acceptThreshold: Double?, answer: AnyCodableValue?) {
            self.name = name; self.model = model; self.margin = margin; self.maxCandidates = maxCandidates; self.acceptThreshold = acceptThreshold; self.answer = answer
        }
        func judge(_ request: JudgeRequest) async -> JudgeAnswer {
            lock.withLock { requests.append(request) }
            guard let answer else { return .unavailable(error: .network) }
            if case .string(let code)? = answer["unavailable"] { return .unavailable(error: JudgeErrorCode(rawValue: code) ?? .network) }
            return .answered(choice: answer["choice"]?.stringValue, probability: answer["probability"]?.doubleValue,
                             confidence: answer["confidence"]?.doubleValue, model: answer["model"]?.stringValue)
        }
    }

    @Test("resolve", arguments: JudgeVectorTests.spec["resolve"]!.arrayValue)
    func resolveCase(_ c: AnyCodableValue) async throws {
        let name = c["name"]?.stringValue ?? "?"
        let j = c["judge"]!
        let stub = StubJudge(name: Self.defaults["judge"]!["name"]!.stringValue!, model: Self.defaults["judge"]!["model"]!.stringValue!,
                             margin: j["margin"]?.doubleValue, maxCandidates: j["maxCandidates"]?.doubleValue.map { Int($0) },
                             acceptThreshold: j["acceptThreshold"]?.doubleValue, answer: j["answer"])
        let intent = try #require(c["intent"]?.stringValue)
        let runtime = try await JudgeCaseRuntime.make(c, intent: intent, judge: stub)
        let args = c["args"].flatMap { v -> [String: any Sendable]? in
            if case .dict(let d) = v { return d.mapValues { $0 as any Sendable } }
            return nil
        }
        let resolution = try await runtime.resolve(intent, options: ResolveOptions(args: args))
        let expect = try #require(c["expect"])
        let requests = stub.lock.withLock { stub.requests }
        #expect(requests.count <= 1, "\(name): asked at most once")
        #expect(!requests.isEmpty == expect["asked"]?.boolValue, "\(name): asked")
        if let first = requests.first {
            #expect(first.trigger.rawValue == expect["trigger"]?.stringValue, "\(name): trigger")
            #expect(first.candidates.map(\.toolId) == expect["offered"]!.arrayValue.compactMap(\.stringValue), "\(name): offered")
            if let descriptions = expect["descriptions"] {
                #expect(first.candidates.map(\.description) == descriptions.arrayValue.compactMap(\.stringValue), "\(name): descriptions")
            }
        }
        #expect(resolution.outcome.rawValue == expect["outcome"]?.stringValue, "\(name): outcome")
        #expect(resolution.proof.decision.rawValue == expect["decision"]?.stringValue, "\(name): decision")
        #expect(resolution.tier.rawValue == expect["tier"]?.stringValue, "\(name): tier")
        #expect(resolution.chosen == expect["chosen"]?.stringValue, "\(name): chosen")
        JudgeCaseRuntime.checkRecord(resolution, expect: expect, name: name, replay: false)
    }

    @Test("replay: a recorded verdict answers in the judge's place", arguments: JudgeVectorTests.spec["replay"]!.arrayValue)
    func replayCase(_ c: AnyCodableValue) async throws {
        let name = c["name"]?.stringValue ?? "?"
        let live = StubJudge(name: Self.defaults["judge"]!["name"]!.stringValue!, model: Self.defaults["judge"]!["model"]!.stringValue!,
                             margin: nil, maxCandidates: nil, acceptThreshold: nil, answer: nil)
        let intent = try #require(c["intent"]?.stringValue)
        let runtime = try await JudgeCaseRuntime.make(c, intent: intent, judge: live)
        let recorded = try #require(RecordedJudgeVerdict(json: c["recorded"]!), "\(name): recorded verdict decodes")
        let resolution = try await runtime.resolve(intent, options: ResolveOptions(judge: .recorded(recorded)))
        #expect(live.lock.withLock { live.requests }.isEmpty, "\(name): replay must not call the judge")
        let expect = try #require(c["expect"])
        #expect(resolution.outcome.rawValue == expect["outcome"]?.stringValue, "\(name): outcome")
        #expect(resolution.proof.decision.rawValue == expect["decision"]?.stringValue, "\(name): decision")
        #expect(resolution.tier.rawValue == expect["tier"]?.stringValue, "\(name): tier")
        #expect(resolution.chosen == expect["chosen"]?.stringValue, "\(name): chosen")
        JudgeCaseRuntime.checkRecord(resolution, expect: expect, name: name, replay: true)
    }

    @Test("wire: a System One response becomes a verdict", arguments: JudgeVectorTests.spec["wire"]!["responses"]!["cases"]!.arrayValue)
    func wireResponse(_ c: AnyCodableValue) async throws {
        let responses = Self.spec["wire"]!["responses"]!
        let offered = responses["offered"]!.arrayValue.compactMap(\.stringValue)
        let model = responses["model"]!.stringValue!
        let status = Int(c["status"]!.doubleValue!)
        let bodyText: String
        if let text = c["bodyText"]?.stringValue { bodyText = text } else { bodyText = try canonicalJSON(c["body"]!) }
        let judge = try JevJudge(apiKey: "sk-test-vectors", options: SystemOneJudgeOptions(model: model, maxRetries: 0, transport: { request in
            (Data(bodyText.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }))
        let answer = await judge.judge(JudgeRequest(intent: "email the invoice", trigger: .ambiguous, candidates: offered.map { JudgeCandidate(toolId: $0, description: $0) }))
        let verdict = acceptJudgeAnswer(answer, offered: offered, acceptThreshold: responses["acceptThreshold"]!.doubleValue!, configuredModel: model)
        let expect = c["expect"]!
        let name = c["name"]?.stringValue ?? "?"
        #expect(verdict.verdict.rawValue == expect["verdict"]?.stringValue, "\(name): verdict")
        #expect(verdict.toolId == expect["toolId"]?.stringValue, "\(name): toolId")
        if let reason = expect["reason"] { #expect(verdict.reason == reason.stringValue, "\(name): reason") }
        if let m = expect["model"] { #expect(verdict.model == m.stringValue, "\(name): model") }
        if let p = expect["probability"] { #expect(verdict.probability == p.doubleValue, "\(name): probability") }
        if let conf = expect["confidence"] { #expect(verdict.confidence == conf.doubleValue, "\(name): confidence") }
    }

    @Test("wire: the request JevJudge sends is the one captured from @typesafe-ai/sdk 0.6.0")
    func wireRequest() async throws {
        let request = Self.spec["wire"]!["request"]!
        let input = request["input"]!
        let want = request["expect"]!
        let seen = Captured()
        let judge = try JevJudge(apiKey: input["apiKey"]!.stringValue!, options: SystemOneJudgeOptions(transport: { req in
            seen.set(req)
            let body = #"{"model":"jev-1.13.0","answers":{"tool":{"type":"choice","choice":"mail/send","confidence":0.8,"probabilities":{"mail/send":0.9}}}}"#
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        let candidates = input["candidates"]!.arrayValue.map { JudgeCandidate(toolId: $0["toolId"]!.stringValue!, description: $0["description"]!.stringValue!) }
        _ = await judge.judge(JudgeRequest(intent: input["intent"]!.stringValue!, trigger: .ambiguous, candidates: candidates))
        let sent = try #require(seen.get())
        #expect(sent.url?.absoluteString == want["url"]?.stringValue)
        #expect(sent.httpMethod == want["method"]?.stringValue)
        for (header, value) in want["headers"]!.dictValue {
            #expect(sent.value(forHTTPHeaderField: header) == value.stringValue, Comment(rawValue: header))
        }
        let body = try parseJSON(sent.httpBody!)
        #expect(body == want["body"]!)
        // The criteria are presented sorted by tool id, abstain last.
        let text = String(decoding: sent.httpBody!, as: UTF8.self)
        let order = want["body"]!["questions"]!["tool"]!["criteria"]!.dictValue.keys.sorted { a, b in
            a == "__none__" ? false : b == "__none__" ? true : Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
        }
        let positions = order.compactMap { text.range(of: "\"\($0)\":")?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted(), "criteria order on the wire")
    }

    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var request: URLRequest?
        func set(_ r: URLRequest) { lock.withLock { request = r } }
        func get() -> URLRequest? { lock.withLock { request } }
    }
}

/// spec/resolve's runtime, plus per-tool descriptions and required parameters, and the stub judge.
enum JudgeCaseRuntime {
    private struct AxisEmbedder: Embedder {
        let intent: String
        let dimensions: Int
        func embed(_ text: String) async throws -> [Float] {
            var v = [Float](repeating: 0, count: dimensions)
            v[text == intent ? 0 : dimensions - 1] = 1
            return v
        }
    }

    private struct ApprovingLLM: LLMClient {
        let approve: [String]
        func verifyMatch(intent: String, toolName: String, toolDescription: String) async -> LLMVerificationResult {
            approve.contains(toolName) ? .verified(confidence: 1) : .rejected(reason: "not approved")
        }
        func decompose(intent: String) async -> LLMDecompositionResult { .unavailable }
        func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String] { [] }
    }

    private final class CaseIMP: ToolIMP, @unchecked Sendable {
        let providerId: String
        let toolName: String
        let transportType: TransportType = .local
        /// Loaded on demand, as the TypeScript harness's schemaLoader is.
        let schema: ToolSchema? = nil
        let loaded: ToolSchema
        let annotations: ToolAnnotations?
        init(providerId: String, toolName: String, description: String, required: [String], annotations: ToolAnnotations?) {
            self.providerId = providerId
            self.toolName = toolName
            var properties: [String: JSONSchemaType] = [:]
            for r in required { properties[r] = JSONSchemaType(type: "string") }
            self.loaded = ToolSchema(
                name: toolName, description: description,
                inputSchema: JSONSchemaType(type: "object", properties: properties.isEmpty ? nil : properties, required: required.isEmpty ? nil : required),
                arguments: required.map { ArgumentSpec(name: $0, type: .init(type: "string"), description: $0, required: true) }
            )
            self.annotations = annotations
        }
        func loadSchema() async throws -> ToolSchema { loaded }
        func execute(args: [String: any Sendable]) async throws -> ToolResult {
            Issue.record("resolve() executed \(providerId)/\(toolName)")
            return ToolResult(content: nil)
        }
    }

    static func selectorOf(_ toolId: String) throws -> String {
        let (providerId, toolName) = try parseToolId(toolId)
        return "\(providerId).\(toolName)"
    }

    static func make(_ c: AnyCodableValue, intent: String, judge: any ShortlistJudge) async throws -> ToolRuntime {
        let tools = c["tools"]!.arrayValue
        let dims = tools.count + 2
        let options = c["options"]
        var config = DispatchConfig()
        if let require = options?["requireLLMForSubHighDispatch"]?.boolValue { config.requireLLMForSubHighDispatch = require }
        if let strict = options?["strict"]?.boolValue { config.strict = strict }
        if let t = options?["thresholds"] {
            config.thresholds = TierThresholds(exact: t["exact"]!.doubleValue!, high: t["high"]!.doubleValue!, medium: t["medium"]!.doubleValue!, low: t["low"]!.doubleValue!)
        }
        let llm: any LLMClient = options?["llm"].map { ApprovingLLM(approve: $0["approve"]!.arrayValue.compactMap(\.stringValue)) } ?? NoOpLLMClient()
        let runtime = ToolRuntime(
            vectorIndex: MemoryVectorIndex(),
            embedder: AxisEmbedder(intent: intent, dimensions: dims),
            options: RuntimeOptions(dispatchConfig: config, llmClient: llm, judge: judge)
        )
        var classes: [String: ToolClass] = [:]
        var order: [String] = []
        for (i, tool) in tools.enumerated() {
            let id = tool["id"]!.stringValue!
            let score = Float(tool["score"]!.doubleValue!)
            let (providerId, toolName) = try parseToolId(id)
            var vector = [Float](repeating: 0, count: dims)
            vector[0] = score
            vector[i + 1] = (1 - score * score).squareRoot()
            let selector = try await runtime.selectorTable.register(embedding: vector, canonical: try selectorOf(id))
            var annotations: ToolAnnotations?
            if case .dict(let a)? = tool["annotations"] {
                annotations = ToolAnnotations(readOnlyHint: a["readOnlyHint"]?.boolValue, destructiveHint: a["destructiveHint"]?.boolValue)
            }
            // "" is an empty description, not an absent one.
            let description = tool["description"]?.stringValue ?? intent
            let required = tool["required"]?.arrayValue.compactMap(\.stringValue) ?? []
            let imp = CaseIMP(providerId: providerId, toolName: toolName, description: description, required: required, annotations: annotations)
            if classes[providerId] == nil {
                classes[providerId] = ToolClass(name: providerId)
                order.append(providerId)
            }
            classes[providerId]!.addMethod(selector, imp: imp)
        }
        for providerId in order { try await runtime.registerClass(classes[providerId]!) }
        return runtime
    }

    /// The proof's `judge` (digested fields, the rest of the record when given) and its `judge` step.
    static func checkRecord(_ resolution: Resolution, expect: AnyCodableValue, name: String, replay: Bool) {
        let judged = resolution.proof.judge
        if let want = expect["judge"], !want.isNull {
            guard let judged else {
                Issue.record("\(name): expected a judge record")
                return
            }
            #expect(judged.name == want["name"]?.stringValue, "\(name): judge name")
            #expect(judged.model == want["model"]?.stringValue, "\(name): judge model")
            #expect(judged.verdict.rawValue == want["verdict"]?.stringValue, "\(name): judge verdict")
            #expect(judged.toolId == want["toolId"]?.stringValue, "\(name): judge toolId")
            if replay { #expect(judged.reason == want["reason"]?.stringValue, "\(name): judge reason") }
        } else {
            #expect(judged == nil, "\(name): no judge record")
        }
        if let record = expect["record"], !record.isNull {
            #expect(judged?.reason == record["reason"]?.stringValue, "\(name): reason")
            #expect(judged?.probability == record["probability"]?.doubleValue, "\(name): probability")
            #expect(judged?.confidence == record["confidence"]?.doubleValue, "\(name): confidence")
            #expect(judged?.margin == record["margin"]?.doubleValue, "\(name): margin")
            #expect(judged.map { Double($0.maxCandidates) } == record["maxCandidates"]?.doubleValue, "\(name): maxCandidates")
        }
        let step = resolution.proof.steps.first { $0.stage == .judge }
        if let want = expect["step"], !want.isNull {
            guard let step else {
                Issue.record("\(name): expected a judge step")
                return
            }
            #expect(step.decision == want["decision"]?.stringValue, "\(name): step decision")
            #expect(step.detail.map { AnyCodableValue.dict($0) } == want["detail"], "\(name): step detail")
        } else {
            #expect(step == nil, "\(name): no judge step")
        }
    }
}
