import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SmallChatRuntime
import SmallChatCore

private extension AnyCodableValue {
    subscript(key: String) -> AnyCodableValue? {
        if case .dict(let object) = self { return object[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var arrayValue: [AnyCodableValue] {
        if case .array(let items) = self { return items }
        return []
    }
}

/// The System One judge family: D1Judge (local, no key), JevJudge (TypeSafe,
/// key required), the context in the state, error codes and option checks.
@Suite("System One judges")
struct SystemOneJudgeTests {
    static let request = JudgeRequest(intent: "email the invoice", trigger: .ambiguous, candidates: [
        JudgeCandidate(toolId: "mail/send", description: "Send an email"),
        JudgeCandidate(toolId: "mail/draft", description: "Save an email draft"),
    ])

    /// What llama-server answers for a d1 GGUF: answers and usage, no model field.
    static func llamaAnswer(_ choice: String, _ p: Double) -> SystemOneTransport {
        { request in
            let body = #"{"answers":{"tool":{"type":"choice","choice":"\#(choice)","confidence":0.77,"probabilities":{"\#(choice)":\#(p),"__none__":\#(1 - p)}}},"usage":{"input_tokens":40,"output_tokens":0}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var all: [URLRequest] { lock.withLock { requests } }
    }

    @Test("D1Judge needs no key, defaults to the local server, and is named d1")
    func d1Defaults() throws {
        let judge = try D1Judge()
        #expect(judge.name == "d1" && judge.model == defaultD1Model && judge.baseURL == defaultD1BaseURL && !judge.authenticated)
        #expect(throws: SystemOneJudgeError.self) { try D1Judge(options: SystemOneJudgeOptions(baseURL: URL(string: "https://judge.example.com")!)) }
        #expect(throws: Never.self) { try D1Judge(options: SystemOneJudgeOptions(baseURL: URL(string: "https://judge.example.com")!, allowRemote: true)) }
        #expect(throws: SystemOneJudgeError.self) { try D1Judge(options: SystemOneJudgeOptions(baseURL: URL(string: "http://judge.example.com")!, allowRemote: true)) }
        let fromEnv = try D1Judge.fromEnvironment(["SMALLCHAT_D1_URL": "http://localhost:9090/", "SMALLCHAT_D1_MODEL": "d1-3B", "SMALLCHAT_D1_API_KEY": "k1"])
        #expect(fromEnv.baseURL.absoluteString == "http://localhost:9090" && fromEnv.model == "d1-3B" && fromEnv.authenticated)
    }

    @Test("sends no Authorization header without a key, and one with; reads llama-server's answer")
    func d1Wire() async throws {
        let seen = Seen()
        let transport: SystemOneTransport = { request in
            seen.add(request)
            return try await Self.llamaAnswer("mail/send", 0.9)(request)
        }
        let judge = try D1Judge(options: SystemOneJudgeOptions(transport: transport))
        let answer = await judge.judge(Self.request)
        #expect(answer == .answered(choice: "mail/send", probability: 0.9, confidence: 0.77, model: nil, requestId: nil))
        #expect(seen.all[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(seen.all[0].url?.absoluteString == "http://127.0.0.1:8080/v1/systemone")
        let keyed = try D1Judge(options: SystemOneJudgeOptions(apiKey: "local-key", transport: transport))
        _ = await keyed.judge(Self.request)
        #expect(seen.all[1].value(forHTTPHeaderField: "Authorization") == "Bearer local-key")
        let verdict = acceptJudgeAnswer(answer, offered: ["mail/draft", "mail/send"], acceptThreshold: 0.7, configuredModel: judge.model)
        #expect(verdict.verdict == .approved && verdict.toolId == "mail/send" && verdict.model == defaultD1Model)
    }

    @Test("context is folded into the state as JSON with instructions that say what it is; sendContext false sends the intent alone")
    func contextState() async throws {
        let context = JudgeContext(sessionId: "sess-1", subject: "invoices",
                                   truth: [JudgeTruthEntry(id: "tb1", type: "TB", status: "active", text: "The rate limit is 60, not 30",
                                                           literals: [.init(subject: "RATE_LIMIT", dead: "30", current: "60")], grade: .verified)],
                                   transcript: [JudgeTranscriptLine(role: .user, text: "please send the invoice")])
        let judge = try D1Judge(options: SystemOneJudgeOptions(transport: Self.llamaAnswer("mail/send", 0.9)))
        var request = Self.request
        request.context = context
        let body = try #require(judge.requestBody(request))
        #expect(body["state"]?["intent"] == .string("email the invoice"))
        #expect(body["state"]?["truth"]?.arrayValue.first?["id"] == .string("tb1"))
        #expect(body["state"]?["transcript"]?.arrayValue.count == 1)
        #expect(body["questions"]?["tool"]?["instructions"]?.stringValue?.contains("\"truth\" lists ledger entries") == true)
        let plain = try D1Judge(options: SystemOneJudgeOptions(sendContext: false, transport: Self.llamaAnswer("mail/send", 0.9)))
        #expect(plain.requestBody(request)?["state"] == .string("email the invoice"))
        #expect(systemOneState(intent: "x", context: nil) == .string("x"))
    }

    @Test("failures map to codes and echo nothing the server said; a server that is down is NETWORK")
    func errors() async throws {
        for (status, code) in [(401, JudgeErrorCode.auth), (429, .rateLimited), (503, .http(503))] {
            let judge = try D1Judge(options: SystemOneJudgeOptions(maxRetries: 0, transport: { request in
                (Data("secret detail".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }))
            let answer = await judge.judge(Self.request)
            guard case .unavailable(let error, _, _, _) = answer else { Issue.record("expected unavailable for \(status)"); continue }
            #expect(error == code)
        }
        let malformed = try D1Judge(options: SystemOneJudgeOptions(transport: { request in
            (Data(#"{"answers":{"tool":{"type":"choice","choice":"mail/send","probabilities":{"mail/send":7}}}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        #expect(await malformed.judge(Self.request) == .unavailable(error: .malformed))
        let down = try D1Judge(options: SystemOneJudgeOptions(maxRetries: 0, transport: { _ in throw URLError(.cannotConnectToHost) }))
        #expect(await down.judge(Self.request) == .unavailable(error: .network))
        #expect(JudgeErrorCode(rawValue: "HTTP_503") == .http(503))
        #expect(JudgeErrorCode(rawValue: "HTTP_x") == nil)
    }

    @Test("JevJudge requires a key, defaults to TypeSafe's pinned model, and retries 5xx within the budget")
    func jev() async throws {
        #expect(throws: SystemOneJudgeError.self) { try JevJudge(apiKey: "") }
        #expect(throws: SystemOneJudgeError.self) { try JevJudge(apiKey: "has space") }
        #expect(throws: SystemOneJudgeError.self) { try JevJudge.fromEnvironment([:]) }
        let judge = try JevJudge(apiKey: "ts_live_SECRET")
        #expect(judge.name == "jev" && judge.model == "jev-1.13.0" && judge.baseURL == defaultJevBaseURL && judge.authenticated)
        #expect(!judge.settingsDescription.contains("SECRET"))
        let calls = Seen()
        let retrying = try JevJudge(apiKey: "ts_live_SECRET", options: SystemOneJudgeOptions(maxRetries: 2, transport: { request in
            calls.add(request)
            if calls.all.count < 3 { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
            return try await Self.llamaAnswer("mail/send", 0.9)(request)
        }))
        let answer = await retrying.judge(Self.request)
        #expect(calls.all.count == 3)
        if case .answered(let choice, _, _, _, _) = answer { #expect(choice == "mail/send") } else { Issue.record("expected an answer after retries") }
    }

    @Test("judgeFromSpec: d1, jev, a URL, or none")
    func spec() throws {
        #expect(try judgeFromSpec(nil, env: [:]) == nil)
        #expect(try judgeFromSpec("d1", env: [:])?.name == "d1")
        #expect(try judgeFromSpec(nil, env: ["SMALLCHAT_JUDGE": "d1"])?.name == "d1")
        #expect(try judgeFromSpec("jev", env: ["TYPESAFE_API_KEY": "k"])?.name == "jev")
        let endpoint = try #require(try judgeFromSpec("http://localhost:5000", env: ["SMALLCHAT_JUDGE_MODEL": "ranker"]))
        #expect(endpoint.name == "endpoint" && endpoint.model == "ranker")
        #expect(throws: SystemOneJudgeError.self) { try judgeFromSpec("magic", env: [:]) }
    }

    @Test("judge rules: margin at the quantum, descriptions folded and cut, settings validated, context bounded")
    func rules() throws {
        #expect(withinJudgeMargin(best: 0.90, score: 0.85, margin: 0.05))
        #expect(!withinJudgeMargin(best: 0.90, score: 0.8499, margin: 0.05))
        #expect(judgeDescription("a\nb\u{2028}c") == "a b c")
        #expect(judgeDescription(String(repeating: "x", count: 300)).utf16.count == 240)
        let emoji = String(repeating: "x", count: 239) + "😀"
        #expect(judgeDescription(emoji).utf16.count == 239)
        #expect(throws: JudgeSettingsError.self) { try judgeSettings(margin: 1) }
        #expect(throws: JudgeSettingsError.self) { try judgeSettings(acceptThreshold: 0) }
        #expect(try judgeSettings().timeoutMs == 4000)
        let wide = JudgeContext(truth: [
            JudgeTruthEntry(id: "uv", type: "UV", status: "open", text: "open claim", grade: .advisory),
            JudgeTruthEntry(id: "tb-a", type: "TB", status: "active", text: "asserted\nfact", grade: .asserted),
            JudgeTruthEntry(id: "tb-v", type: "TB", status: "active", text: String(repeating: "x", count: 600), grade: .verified),
            JudgeTruthEntry(id: "bad", type: "XX", status: "active", text: "dropped"),
        ], transcript: [.init(role: .user, text: "one"), .init(role: .assistant, text: "two"), .init(role: .user, text: "three")])
        let bounded = try #require(boundJudgeContext(wide, limits: JudgeContextLimits(maxTruth: 2, maxTranscript: 2, maxTextChars: 10)))
        #expect(bounded.truth?.map(\.id) == ["tb-v", "tb-a"])
        #expect(bounded.truth?[1].text == "asserted f")
        #expect(bounded.transcript?.map(\.text) == ["two", "three"])
        #expect(boundJudgeContext(nil) == nil)
        #expect(boundJudgeContext(JudgeContext()) == nil)
    }
}
