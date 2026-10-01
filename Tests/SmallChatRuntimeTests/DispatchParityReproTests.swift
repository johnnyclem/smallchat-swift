import Foundation
import Testing
@testable import SmallChatRuntime
import SmallChatCore
import SmallChatEmbedding

// SC-SW-04, SC-SW-15 and SC-SW-25. Written against the 0.6 runtime first,
// where every test here failed (13 issues); the scenarios are unchanged,
// ported from 0.6's `tieredDispatch` to `resolve` / `dispatch`.

/// Embeds `intent` as e0 and everything else as the last axis.
private struct AxisEmbedder: Embedder {
    let intent: String
    let dimensions: Int
    func embed(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[text == intent ? 0 : dimensions - 1] = 1
        return v
    }
}

private final class CountingIMP: ToolIMP, @unchecked Sendable {
    let providerId: String
    let toolName: String
    let transportType: TransportType = .local
    let description: String
    let annotations: ToolAnnotations?
    private let lock = NSLock()
    private var _runs = 0
    var runs: Int { lock.withLock { _runs } }
    var schema: ToolSchema? { ToolSchema(name: toolName, description: description, inputSchema: JSONSchemaType(type: "object")) }

    init(providerId: String, toolName: String, description: String, annotations: ToolAnnotations? = nil) {
        self.providerId = providerId
        self.toolName = toolName
        self.description = description
        self.annotations = annotations
    }

    func loadSchema() async throws -> ToolSchema { schema! }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        lock.withLock { _runs += 1 }
        return ToolResult(content: "ran \(toolName)")
    }
}

/// A runtime where each tool's cosine similarity to `intent` is as given.
private func makeRuntime(
    intent: String,
    tools: [(provider: String, name: String, score: Float, description: String)],
    config: DispatchConfig = DispatchConfig(),
    annotations: ToolAnnotations? = nil
) async throws -> (ToolRuntime, [CountingIMP]) {
    let dims = tools.count + 2
    let runtime = ToolRuntime(
        vectorIndex: MemoryVectorIndex(),
        embedder: AxisEmbedder(intent: intent, dimensions: dims),
        options: RuntimeOptions(dispatchConfig: config)
    )
    var imps: [CountingIMP] = []
    var classes: [String: ToolClass] = [:]
    for (i, tool) in tools.enumerated() {
        var vector = [Float](repeating: 0, count: dims)
        vector[0] = tool.score
        vector[i + 1] = (1 - tool.score * tool.score).squareRoot()
        let selector = try await runtime.selectorTable.register(embedding: vector, canonical: "\(tool.provider).\(tool.name)")
        let imp = CountingIMP(providerId: tool.provider, toolName: tool.name, description: tool.description, annotations: annotations)
        imps.append(imp)
        let cls = classes[tool.provider] ?? ToolClass(name: tool.provider)
        cls.addMethod(selector, imp: imp)
        classes[tool.provider] = cls
    }
    for cls in classes.values { try await runtime.registerClass(cls) }
    return (runtime, imps)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Dispatch parity (SC-SW-04, SC-SW-15, SC-SW-25)")
struct DispatchParityReproTests {

    @Test("SC-SW-04: repeating an intent does not run a tool the first call refused")
    func cacheDoesNotLaunderRefusal() async throws {
        let intent = "purge everything quickly"
        let (runtime, imps) = try await makeRuntime(
            intent: intent,
            tools: [
                ("db", "drop_table", 0.90, "remove a relation"),
                ("db", "drop_index", 0.87, "remove an index structure"),
            ],
            annotations: ToolAnnotations(destructiveHint: true)
        )
        let first = try await runtime.dispatch(intent, args: [:])
        let second = try await runtime.dispatch(intent, args: [:])
        #expect(first.metadata?["outcome"] as? String == "needs-disambiguation")
        #expect(second.metadata?["outcome"] as? String == first.metadata?["outcome"] as? String)
        #expect(imps.map(\.runs).reduce(0, +) == 0)
    }

    @Test("SC-SW-04: the same intent reaches the same decision every time (0.90 / 0.87)")
    func repeatedIntentSameDecision() async throws {
        let intent = "purge everything quickly"
        let (runtime, imps) = try await makeRuntime(intent: intent, tools: [
            ("db", "drop_table", 0.90, "remove a relation"),
            ("db", "drop_index", 0.87, "remove an index structure"),
        ])
        let first = try await runtime.dispatch(intent, args: [:])
        let second = try await runtime.dispatch(intent, args: [:])
        let firstProof = first.metadata?["proof"] as? ResolutionProof
        let secondProof = second.metadata?["proof"] as? ResolutionProof
        #expect(firstProof?.outcome == secondProof?.outcome)
        #expect(firstProof?.chosen == secondProof?.chosen)
        #expect(secondProof?.decision == .cache)
        #expect(imps.map(\.runs) == [2, 0])
    }

    @Test("SC-SW-04: strict mode is not bypassed by a cache hit")
    func strictCacheHit() async throws {
        let intent = "purge everything quickly"
        let (runtime, imps) = try await makeRuntime(
            intent: intent,
            tools: [
                ("db", "drop_table", 0.90, "remove a relation"),
                ("db", "drop_index", 0.87, "remove an index structure"),
            ],
            config: DispatchConfig(strict: true)
        )
        _ = try await runtime.dispatch(intent, args: [:])
        _ = try await runtime.dispatch(intent, args: [:])
        #expect(imps.map(\.runs).reduce(0, +) == 0)
    }

    @Test("SC-SW-04: a cache hit is judged again, so a pin added later still refuses it")
    func cacheHitIsJudgedAgain() async throws {
        let intent = "purge everything quickly"
        let (runtime, imps) = try await makeRuntime(intent: intent, tools: [
            ("db", "drop_table", 0.90, "remove a relation"),
        ])
        let first = try await runtime.dispatch(intent, args: [:])
        #expect(first.metadata?["outcome"] as? String == "resolved")
        await runtime.context.intentPins.pin(IntentPin(canonical: "db.drop_table", policy: .exact, aliases: ["drop the table"]))
        let second = try await runtime.dispatch(intent, args: [:])
        #expect(second.isError)
        #expect(imps[0].runs == 1)
    }

    @Test("a near miss below LOW is never executed by intent")
    func nearMissNeverRuns() async throws {
        let intent = "send the quarterly report"
        let (runtime, imps) = try await makeRuntime(intent: intent, tools: [
            ("fs", "delete_file", 0.55, "delete a file"),
        ])
        let result = try await runtime.dispatch(intent, args: [:])
        #expect(result.isError)
        #expect(imps[0].runs == 0)
    }

    @Test("SC-SW-15: canonicalize deletes punctuation (TS 1.0), keeps non-Latin letters")
    func canonicalForm() {
        #expect(canonicalize("search_code for foo-bar") == "searchcode:foobar")
        #expect(canonicalize("don't delete the prod database") == "dont:delete:prod:database")
        #expect(canonicalize("créer un fichier") == "créer:un:fichier")
    }

    @Test("SC-SW-15: default tier thresholds are .95/.85/.75/.60")
    func defaultTiers() {
        #expect(DispatchConfig().tier(for: 0.72) == .low)
        #expect(DispatchConfig().tier(for: 0.96) == .exact)
        #expect(DispatchConfig().tier(for: 0.74) == .low)
        #expect(DispatchConfig().tier(for: 0.59) == .none)
    }

    @Test("SC-SW-15: a negated phrase does not match an exact pin's alias")
    func pinNegation() {
        let pins = IntentPinRegistry()
        pins.pin(IntentPin(canonical: "bank.transfer", policy: .exact, aliases: ["transfer funds"]))
        // 0.6 compared canonical forms, which drop "do" and "not".
        let intent = "do not transfer funds"
        let match = pins.checkExact(canonicalize(intent)) ?? pins.checkExact(intent)
        #expect(match == nil)
    }

    @Test("SC-SW-25: strict mode never auto-runs a MEDIUM match")
    func strictMedium() async throws {
        let intent = "look up issue"
        let runtime = ToolRuntime(
            vectorIndex: MemoryVectorIndex(),
            embedder: AxisEmbedder(intent: intent, dimensions: 3),
            options: RuntimeOptions(dispatchConfig: DispatchConfig(strict: true))
        )
        let runs = Counter()
        let proxy = ToolProxy(
            providerId: "github",
            toolName: "get_issue",
            transportType: .local,
            schemaLoader: { ToolSchema(name: "get_issue", description: intent, inputSchema: JSONSchemaType(type: "object")) },
            executor: { _ in runs.increment(); return ToolResult(content: "ran") }
        )
        let selector = try await runtime.selectorTable.register(embedding: [0.8, 0.6, 0], canonical: "github.get_issue")
        let cls = ToolClass(name: "github")
        cls.addMethod(selector, imp: proxy)
        try await runtime.registerClass(cls)
        let result = try await runtime.dispatch(intent, args: [:])
        #expect(runs.value == 0)
        #expect((result.metadata?["proof"] as? ResolutionProof)?.decision == .needsLLMVerifier)
    }

    @Test("SC-SW-25: snake_case tool names contribute keywords")
    func snakeCaseKeywords() {
        #expect(keywordOverlap(intent: "delete production records", toolName: "delete_records", toolDescription: "delete_records") > 0)
    }
}
