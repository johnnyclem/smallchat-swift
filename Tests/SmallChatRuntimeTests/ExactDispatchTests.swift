import Foundation
import Testing
@testable import SmallChatRuntime
import SmallChatCore
import SmallChatEmbedding

/// Records which tools ran, with which arguments.
private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, [String: any Sendable])] = []
    func add(_ toolId: String, _ args: [String: any Sendable]) { lock.withLock { entries.append((toolId, args)) } }
    var ids: [String] { lock.withLock { entries.map(\.0) } }
}

/// Embeds each known text as a fixed vector; anything else as the last axis.
private struct TableEmbedder: Embedder {
    let vectors: [String: [Float]]
    let dimensions: Int
    func embed(_ text: String) async throws -> [Float] {
        if let v = vectors[text] { return v }
        var v = [Float](repeating: 0, count: dimensions)
        v[dimensions - 1] = 1
        return v
    }
}

private struct Decomposer: LLMClient {
    let parts: [String: [String]]
    var providesVerification: Bool { false }
    func verifyMatch(intent: String, toolName: String, toolDescription: String) async -> LLMVerificationResult { .unavailable }
    func decompose(intent: String) async -> LLMDecompositionResult {
        parts[intent].map { .decomposed(subIntents: $0) } ?? .atomic
    }
    func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String] { [] }
}

/// notes/create_note (requires a string title) and notes/delete_note
/// (destructive). Intents: "create a note" -> create at 0.9, "remove a note"
/// -> delete at 0.9, "tidy up" -> create at 0.65 (LOW).
private func notesRuntime(runs: Runs, options: RuntimeOptions = RuntimeOptions()) async throws -> ToolRuntime {
    let embedder = TableEmbedder(vectors: [
        "create a note": [1, 0, 0, 0],
        "remove a note": [0, 1, 0, 0],
        // cos(tidy up, create_note) = 0.9 * 0.7222 = 0.65
        "tidy up": [0.7222222, 0, (Float(1) - 0.7222222 * 0.7222222).squareRoot(), 0],
    ], dimensions: 4)
    let runtime = ToolRuntime(vectorIndex: MemoryVectorIndex(), embedder: embedder, options: options)
    let createSchema = JSONSchemaType(json: [
        "type": .string("object"),
        "properties": .dict(["title": .dict(["type": .string("string")])]),
        "required": .array([.string("title")]),
        "additionalProperties": .bool(false),
    ])
    let create = ToolProxy(
        providerId: "notes", toolName: "create_note", transportType: .local,
        schemaLoader: { ToolSchema(name: "create_note", description: "create a note", inputSchema: createSchema) },
        executor: { args in runs.add("notes/create_note", args); return ToolResult(content: "created") }
    )
    let delete = ToolProxy(
        providerId: "notes", toolName: "delete_note", transportType: .local,
        schemaLoader: { ToolSchema(name: "delete_note", description: "remove a note", inputSchema: JSONSchemaType(type: "object")) },
        executor: { args in runs.add("notes/delete_note", args); return ToolResult(content: "deleted") },
        annotations: ToolAnnotations(destructiveHint: true)
    )
    let createSelector = try await runtime.selectorTable.register(embedding: [0.9, 0, 0, (Float(1) - 0.81).squareRoot()], canonical: "notes.create_note")
    let deleteSelector = try await runtime.selectorTable.register(embedding: [0, 0.9, 0, (Float(1) - 0.81).squareRoot()], canonical: "notes.delete_note")
    let cls = ToolClass(name: "notes")
    cls.addMethod(createSelector, imp: create)
    cls.addMethod(deleteSelector, imp: delete)
    try await runtime.registerClass(cls)
    return runtime
}

private func outcome(_ result: ToolResult) -> String? { result.metadata?["outcome"] as? String }
private func proof(_ result: ToolResult) -> ResolutionProof? { result.metadata?["proof"] as? ResolutionProof }

@Suite("Resolve vs. execute, exact dispatch and argument validation")
struct ExactDispatchTests {

    @Test("dispatchById runs exactly the named tool and records the call digest")
    func dispatchByIdRuns() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        let result = try await runtime.dispatchById("notes/create_note", args: ["title": "groceries"])
        #expect(result.content as? String == "created")
        #expect(runs.ids == ["notes/create_note"])
        #expect(outcome(result) == "resolved")
        let p = try #require(proof(result))
        #expect(p.decision == .exactId)
        #expect(p.ran == "notes/create_note")
        #expect(p.callDigest == (try callDigest(toolId: "notes/create_note", arguments: ["title": .string("groceries")])))
    }

    @Test("a destructive tool runs by exact id")
    func destructiveById() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        _ = try await runtime.dispatchById("notes/delete_note")
        #expect(runs.ids == ["notes/delete_note"])
    }

    @Test("an unknown id runs nothing")
    func unknownId() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        for id in ["create_note", "notes/create", "notes.create_note"] {
            let result = try await runtime.dispatchById(id)
            #expect(result.isError)
            #expect(outcome(result) == "unresolved")
            #expect(proof(result)?.decision == .unknownTool)
        }
        #expect(runs.ids.isEmpty)
    }

    @Test("arguments that fail the inputSchema run nothing, by id or by intent")
    func invalidArguments() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        for args: [String: any Sendable] in [[:], ["title": 5], ["title": "x", "extra": true]] {
            let byId = try await runtime.dispatchById("notes/create_note", args: args)
            #expect(byId.isError)
            #expect(outcome(byId) == "invalid-arguments")
            #expect(proof(byId)?.ran == nil)
            let byIntent = try await runtime.dispatch("create a note", args: args)
            #expect(outcome(byIntent) == "invalid-arguments")
        }
        #expect(runs.ids.isEmpty)
        let ok = try await runtime.dispatch("create a note", args: ["title": "x"])
        #expect(outcome(ok) == "resolved")
        #expect(runs.ids == ["notes/create_note"])
    }

    @Test("resolve never executes; dispatchById can link the resolution it acts on")
    func resolveThenRun() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        let resolution = try await runtime.resolve("create a note")
        #expect(resolution.outcome == .resolved)
        #expect(resolution.chosen == "notes/create_note")
        #expect(resolution.tier == .high)
        #expect(runs.ids.isEmpty)

        let result = try await runtime.dispatchById(
            resolution.chosen!,
            args: ["title": "x"],
            options: DispatchByIdOptions(resolutionDigest: resolution.proof.proofDigest)
        )
        #expect(proof(result)?.resolutionDigest == resolution.proof.proofDigest)
        #expect(runs.ids == ["notes/create_note"])
    }

    @Test("a destructive tool is never run by a HIGH intent match")
    func destructiveByIntent() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        let result = try await runtime.dispatch("remove a note", args: [:])
        #expect(outcome(result) == "needs-disambiguation")
        #expect(proof(result)?.decision == .destructiveNeedsExact)
        let refinement = result.metadata?["refinement"] as? ToolRefinement
        #expect(refinement?.nearMatches.map(\.toolId) == ["notes/delete_note"])
        #expect(runs.ids.isEmpty)
    }

    @Test("the same intent gives the same proof digest, whatever was resolved before")
    func deterministicProofs() async throws {
        let runtime = try await notesRuntime(runs: Runs())
        let first = try await runtime.resolve("create a note")
        _ = try await runtime.resolve("remove a note")
        _ = try await runtime.resolve("tidy up")
        let again = try await runtime.resolve("create a note")
        #expect(first.proof.proofDigest == again.proof.proofDigest)
        #expect(first.proof.proofDigest.count == 64)
    }

    @Test("the opt-in rate limiter throttles a principal without throwing")
    func throttled() async throws {
        let runtime = try await notesRuntime(runs: Runs(), options: RuntimeOptions(
            rateLimiter: SemanticRateLimiterOptions(maxNovelIntents: 1)
        ))
        let first = try await runtime.resolve("create a note", options: ResolveOptions(principal: "alice"))
        #expect(first.outcome == .resolved)
        let second = try await runtime.resolve("remove a note", options: ResolveOptions(principal: "alice"))
        #expect(second.outcome == .throttled)
        #expect(second.proof.decision == .rateLimited)
        #expect((second.retryAfterMs ?? 0) > 0)
        // Another principal has its own window.
        let other = try await runtime.resolve("remove a note", options: ResolveOptions(principal: "bob"))
        #expect(other.outcome != .throttled)
    }

    @Test("a LOW intent the LLM decomposes runs each sub-intent through the same policy, within the budget")
    func decomposition() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs, options: RuntimeOptions(
            dispatchConfig: DispatchConfig(maxSubDispatches: 2),
            llmClient: Decomposer(parts: ["tidy up": ["create a note", "remove a note", "create a note again"]])
        ))
        let result = try await runtime.dispatch("tidy up", args: [:])
        #expect(proof(result)?.decision == .decomposed)
        // "create a note" has no title: invalid arguments; "remove a note" is
        // destructive: refused; the third is past the budget. Nothing ran.
        #expect(runs.ids.isEmpty)
        #expect(result.isError)
        let content = try #require(result.content as? [String: any Sendable])
        let entries = try #require(content["results"] as? [[String: any Sendable]])
        #expect(entries.count == 3)
        let outcomes = entries.map { ($0["metadata"] as? [String: any Sendable])?["outcome"] as? String }
        #expect(outcomes == ["invalid-arguments", "needs-disambiguation", "not-dispatched"])
    }

    @Test("streaming by id validates, then runs exactly that tool")
    func streamById() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        var sawStart = false
        var done: ToolResult?
        for try await event in await runtime.dispatchStreamById("notes/create_note", args: ["title": "x"]) {
            if case .toolStart = event { sawStart = true }
            if case .done(let result) = event { done = result }
        }
        #expect(sawStart)
        #expect(done?.content as? String == "created")
        #expect(runs.ids == ["notes/create_note"])

        var sawError = false
        for try await event in await runtime.dispatchStreamById("notes/create_note", args: [:]) {
            if case .error = event { sawError = true }
            if case .toolStart = event { Issue.record("must not start a tool with invalid arguments") }
        }
        #expect(sawError)
        #expect(runs.ids == ["notes/create_note"])
    }

    @Test("a registry change flushes cached resolutions")
    func registryFlushesCache() async throws {
        let runs = Runs()
        let runtime = try await notesRuntime(runs: runs)
        _ = try await runtime.resolve("create a note")
        #expect(await runtime.cache.size == 0) // a plain resolve learns nothing
        _ = try await runtime.dispatch("create a note", args: ["title": "x"])
        #expect(await runtime.cache.size == 1)
        try await runtime.registerClass(ToolClass(name: "other"))
        #expect(await runtime.cache.size == 0)
    }
}
