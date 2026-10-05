import Testing
import Foundation
@testable import SmallChatRuntime

@Suite("JevJudge")
struct JevJudgeTests {
    @Test func triggerMatchesTheRuntimeAmbiguousStamp() {
        #expect(jevTrigger(bestTier: .high, bestScore: 0.88, candidateCount: 2) == .ambiguous)
        #expect(jevTrigger(bestTier: .medium, bestScore: 0.70, candidateCount: 1) == .lowConfidence)
        #expect(jevTrigger(bestTier: .high, bestScore: 0.91, candidateCount: 2) == nil)
    }

    @Test func acceptsAShortlistedId() async {
        let judge = JevJudge(apiKey: "test", transport: { _ in
            let body = """
            {"answers":{"tool":{"type":"choice","choice":"mail/send","confidence":0.78,"probabilities":{"mail/send":0.84,"__none__":0.16}}}}
            """.data(using: .utf8)!
            return (body, HTTPURLResponse(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let verdict = await judge.judge(
            intent: "email the invoice",
            candidates: [JevCandidate(toolId: "mail/send", description: "Send an email", score: 0.62)],
            trigger: .ambiguous
        )
        #expect(verdict.toolId == "mail/send")
        #expect(verdict.probability == 0.84)
    }

    @Test func declinesAnUnknownIdAndALowProbability() async {
        let unknown = JevJudge(apiKey: "test", transport: { _ in
            let body = """
            {"answers":{"tool":{"type":"choice","choice":"mail/delete","confidence":0.99,"probabilities":{"mail/delete":0.99}}}}
            """.data(using: .utf8)!
            return (body, HTTPURLResponse(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let declined = await unknown.judge(
            intent: "email",
            candidates: [JevCandidate(toolId: "mail/send", description: "Send", score: 0.6)],
            trigger: .lowConfidence
        )
        #expect(declined.toolId == nil)

        let low = JevJudge(apiKey: "test", acceptThreshold: 0.7, transport: { _ in
            let body = """
            {"answers":{"tool":{"type":"choice","choice":"mail/send","confidence":0.2,"probabilities":{"mail/send":0.42}}}}
            """.data(using: .utf8)!
            return (body, HTTPURLResponse(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let weak = await low.judge(
            intent: "email",
            candidates: [JevCandidate(toolId: "mail/send", description: "Send", score: 0.6)],
            trigger: .ambiguous
        )
        #expect(weak.toolId == nil)
    }
}
