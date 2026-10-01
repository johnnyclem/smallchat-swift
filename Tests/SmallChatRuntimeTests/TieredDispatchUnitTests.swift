import Testing
@testable import SmallChatRuntime
import SmallChatCore

@Suite("Tiered dispatch unit pieces")
struct TieredDispatchUnitTests {

    // MARK: - Verification

    private final class SchemaIMP: ToolIMP, @unchecked Sendable {
        let providerId = "p"
        let toolName: String
        let transportType: TransportType = .local
        let schema: ToolSchema?
        init(name: String, description: String, arguments: [ArgumentSpec] = []) {
            toolName = name
            schema = ToolSchema(name: name, description: description, inputSchema: JSONSchemaType(type: "object"), arguments: arguments)
        }
        func loadSchema() async throws -> ToolSchema { schema! }
        func execute(args: [String: any Sendable]) async throws -> ToolResult { ToolResult(content: nil) }
    }

    @Test("Verification fails when required arguments are missing")
    func verifyMissingArgs() async {
        let imp = SchemaIMP(name: "send_message", description: "Send a chat message to a user", arguments: [
            ArgumentSpec(name: "recipient", type: .init(type: "string"), description: "user id", required: true),
            ArgumentSpec(name: "body", type: .init(type: "string"), description: "message body", required: true),
        ])
        let result = await verify(imp, intent: "send a message to alice", args: ["recipient": "alice"])
        #expect(result.passed == false)
        #expect(result.schemaMatch == false)
    }

    @Test("Keyword overlap rejects intents with no shared salient terms")
    func keywordOverlapRejects() async {
        let imp = SchemaIMP(name: "compile_typescript", description: "Run the TypeScript compiler over a project")
        let result = await verify(imp, intent: "what is the weather forecast for tomorrow", args: [:], options: VerificationOptions(skipSchemaCheck: true))
        #expect(result.passed == false)
        #expect(result.schemaMatch == true)
        #expect(result.descriptionOverlap < 0.15)
    }

    @Test("Keyword overlap accepts intents with shared salient terms")
    func keywordOverlapAccepts() async {
        let imp = SchemaIMP(name: "loom_find_importers", description: "find callers and importers of a function symbol")
        let result = await verify(imp, intent: "find callers of the loginUser function", args: [:], options: VerificationOptions(skipSchemaCheck: true))
        #expect(result.passed == true)
    }

    @Test("An LLM verifier is asked when its answer authorizes the call, and can refuse")
    func llmVerifierRefuses() async {
        struct Refuses: LLMClient {
            func verifyMatch(intent: String, toolName: String, toolDescription: String) async -> LLMVerificationResult { .rejected(reason: "no") }
            func decompose(intent: String) async -> LLMDecompositionResult { .unavailable }
            func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String] { [] }
        }
        let imp = SchemaIMP(name: "loom_find_importers", description: "find callers and importers of a function symbol")
        let result = await verify(imp, intent: "find callers of the loginUser function", args: [:], llm: Refuses(),
                                  options: VerificationOptions(forceLLMCheck: true, skipSchemaCheck: true))
        #expect(result.passed == false)
        #expect(result.llmConfirmed == false)
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
