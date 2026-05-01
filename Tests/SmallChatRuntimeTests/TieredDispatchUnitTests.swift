import Testing
@testable import SmallChatRuntime
import SmallChatCore

@Suite("Tiered dispatch unit pieces")
struct TieredDispatchUnitTests {

    // MARK: - Verification

    @Test("Verification fails when required arguments are missing")
    func verifyMissingArgs() async {
        let result = await verifyCandidate(
            intent: "send a message to alice",
            toolName: "send_message",
            toolDescription: "Send a chat message to a user",
            arguments: [
                ArgumentSpec(name: "recipient", type: .init(type: "string"), description: "user id", required: true),
                ArgumentSpec(name: "body", type: .init(type: "string"), description: "message body", required: true),
            ],
            suppliedArgs: ["recipient": "alice"]
        )
        #expect(result.passed == false)
        #expect(result.strategy == .schema)
    }

    @Test("Keyword overlap rejects intents with no shared salient terms")
    func keywordOverlapRejects() async {
        let result = await verifyCandidate(
            intent: "what is the weather forecast for tomorrow",
            toolName: "compile_typescript",
            toolDescription: "Run the TypeScript compiler over a project",
            arguments: [],
            suppliedArgs: nil
        )
        #expect(result.passed == false)
        #expect(result.strategy == .keywordOverlap)
    }

    @Test("Keyword overlap accepts intents with shared salient terms")
    func keywordOverlapAccepts() async {
        let result = await verifyCandidate(
            intent: "find callers of the loginUser function",
            toolName: "loom_find_importers",
            toolDescription: "find callers and importers of a function symbol",
            arguments: [],
            suppliedArgs: nil
        )
        #expect(result.passed == true)
    }

    @Test("Standalone keywordOverlap helper returns Jaccard between meaningful tokens")
    func keywordOverlapHelperRange() {
        let overlap = keywordOverlap(
            intent: "find callers of foo",
            toolName: "loom_find_importers",
            toolDescription: "find callers of a symbol"
        )
        #expect(overlap > 0.0)
        #expect(overlap <= 1.0)
    }

    // MARK: - Decomposition

    @Test("Rule-based decomposition splits 'then' conjunctions")
    func decomposeThen() async {
        let r = await decomposeIntent("index this folder then list repos")
        #expect(r.didDecompose)
        #expect(r.subIntents.count == 2)
        #expect(r.strategy == .rule)
    }

    @Test("Atomic intents pass through unchanged")
    func decomposeAtomic() async {
        let r = await decomposeIntent("index this folder")
        #expect(r.didDecompose == false)
        #expect(r.subIntents == ["index this folder"])
    }

    @Test("Rule-based decomposition handles semicolon separators")
    func decomposeSemicolon() async {
        let r = await decomposeIntent("show topology; list repos; get metrics")
        #expect(r.didDecompose)
        #expect(r.subIntents.count == 3)
    }

    // MARK: - DispatchObserver

    @Test("Observer adapts threshold upward after corrections")
    func observerAdapts() async {
        let observer = DispatchObserver(baseThreshold: 0.85, maxThreshold: 0.97, perCorrectionStep: 0.03)
        await observer.record(.corrected(intendedTool: "a.bar", actualTool: "a.foo", tier: .medium))
        await observer.record(.corrected(intendedTool: "a.bar", actualTool: "a.foo", tier: .medium))
        let recommended = await observer.recommendedThreshold(for: "a.foo")
        #expect(recommended > 0.85)
        #expect(recommended <= 0.97)
    }

    @Test("Observer leaves unseen tools at the base threshold")
    func observerBase() async {
        let observer = DispatchObserver()
        let recommended = await observer.recommendedThreshold(for: "never.seen")
        #expect(recommended == 0.85)
    }

    @Test("NoOpLLMClient stays out of the way")
    func noopLLM() async {
        let client = NoOpLLMClient()
        let v = await client.verifyMatch(intent: "x", toolName: "y", toolDescription: "z")
        #expect(v == .unavailable)
        let d = await client.decompose(intent: "x")
        #expect(d == .unavailable)
        let q = await client.clarifyingQuestions(intent: "x", nearMatches: ["y"])
        #expect(q.isEmpty)
    }
}
