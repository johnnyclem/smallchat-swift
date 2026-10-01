import Foundation
import Testing
@testable import SmallChatRuntime
import SmallChatCore
import SmallChatEmbedding

/// Records which tools ran.
private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ toolId: String) { lock.withLock { entries.append(toolId) } }
    var ids: [String] { lock.withLock { entries } }
}

/// Embeds each known text as a fixed vector, anything else as the last
/// axis; counts calls and can take its time.
private final class SlowTableEmbedder: Embedder, @unchecked Sendable {
    let vectors: [String: [Float]]
    let dimensions = 4
    let delay: Duration
    private let lock = NSLock()
    private var count = 0

    init(_ vectors: [String: [Float]], delay: Duration = .zero) {
        self.vectors = vectors
        self.delay = delay
    }

    var calls: Int { lock.withLock { count } }

    func embed(_ text: String) async throws -> [Float] {
        lock.withLock { count += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let v = vectors[text] { return v }
        var v = [Float](repeating: 0, count: dimensions)
        v[dimensions - 1] = 1
        return v
    }
}

/// Opens once; every wait before that suspends.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let (arrivals, arrived) = AsyncStream<Void>.makeStream()

    func wait() async {
        arrived.yield()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    /// Returns once something is waiting.
    func firstArrival() async {
        var iterator = arrivals.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for cont in pending { cont.resume() }
    }
}

/// "go" matches a/t at 0.9 (HIGH), a/u at 0.7 (LOW) and, once class b is
/// registered, b/t at 0.99 (EXACT). The tools are read-only, so dispatch
/// caches them. Two matches in class a give resolution a suspension point
/// between choosing a/t and caching it.
private func raceRuntime(ran: Ran, schemaGate: Gate? = nil, options: RuntimeOptions = RuntimeOptions(),
                         embedder: SlowTableEmbedder? = nil) async throws -> (ToolRuntime, ToolProxy) {
    let embedder = embedder ?? SlowTableEmbedder(["go": [1, 0, 0, 0]])
    let runtime = ToolRuntime(vectorIndex: MemoryVectorIndex(), embedder: embedder, options: options)
    let tool = readOnlyTool("a", "t", ran: ran, schemaGate: schemaGate)
    let selector = try await runtime.selectorTable.register(embedding: [0.9, 0, 0, (Float(1) - 0.81).squareRoot()], canonical: "a.t")
    let other = try await runtime.selectorTable.register(embedding: [0.7, 0, 0, (Float(1) - 0.49).squareRoot()], canonical: "a.u")
    let cls = ToolClass(name: "a")
    cls.addMethod(selector, imp: tool)
    cls.addMethod(other, imp: readOnlyTool("a", "u", ran: ran))
    try await runtime.registerClass(cls)
    return (runtime, tool)
}

private func readOnlyTool(_ provider: String, _ name: String, ran: Ran, schemaGate: Gate? = nil) -> ToolProxy {
    ToolProxy(
        providerId: provider, toolName: name, transportType: .local,
        schemaLoader: {
            await schemaGate?.wait()
            return ToolSchema(name: name, description: name, inputSchema: JSONSchemaType(type: "object"))
        },
        executor: { _ in ran.add("\(provider)/\(name)"); return ToolResult(content: "ok") },
        annotations: ToolAnnotations(readOnlyHint: true)
    )
}

private func registerB(_ runtime: ToolRuntime, ran: Ran) async throws {
    let selector = try await runtime.selectorTable.register(embedding: [0.99, 0, 0, (Float(1) - 0.9801).squareRoot()], canonical: "b.t")
    let cls = ToolClass(name: "b")
    cls.addMethod(selector, imp: readOnlyTool("b", "t", ran: ran))
    try await runtime.registerClass(cls)
}

private func outcome(_ result: ToolResult) -> String? { result.metadata?[DispatchMetadataKey.outcome] as? String }

@Suite("Registry changes and in-flight dispatches (SW-REV-02, SW-REV-06)", .timeLimit(.minutes(1)))
struct RegistryRaceTests {

    @Test("a cached resolution of an unregistered tool is never run")
    func unregisteredToolNotRunFromCache() async throws {
        let ran = Ran()
        let (runtime, tool) = try await raceRuntime(ran: ran)
        _ = try await runtime.dispatch("go", args: [:])
        #expect(ran.ids == ["a/t"])
        #expect(await runtime.cache.size == 1)

        #expect(await runtime.unregisterClass("a"))
        // A resolution that raced the unregistration stores its pick after the flush.
        await runtime.cache.store(ToolSelector.intent("go", vector: [1, 0, 0, 0]), imp: tool, confidence: 0.9)
        let result = try await runtime.dispatch("go", args: [:])
        #expect(result.isError)
        #expect(ran.ids == ["a/t"], "a/t ran after its class was unregistered")
    }

    @Test("a decision cached before the registry changed is not reused")
    func staleDecisionNotReused() async throws {
        let ran = Ran()
        let (runtime, tool) = try await raceRuntime(ran: ran)
        _ = try await runtime.dispatch("go", args: [:])
        try await registerB(runtime, ran: ran)
        // A resolution that started before b was registered stores a/t after the flush.
        await runtime.cache.store(ToolSelector.intent("go", vector: [1, 0, 0, 0]), imp: tool, confidence: 0.9)
        _ = try await runtime.dispatch("go", args: [:])
        #expect(ran.ids == ["a/t", "b/t"], "a fresh resolution picks b/t")
    }

    @Test("an entry stamped with an earlier registry generation is a miss")
    func olderGenerationIsAMiss() async throws {
        let ran = Ran()
        let (runtime, tool) = try await raceRuntime(ran: ran)
        let before = await runtime.context.registryGeneration
        try await registerB(runtime, ran: ran)
        #expect(await runtime.context.registryGeneration != before)
        await runtime.cache.store(ToolSelector.intent("go", vector: [1, 0, 0, 0]), imp: tool, confidence: 0.9,
                                  registryGeneration: before)
        _ = try await runtime.dispatch("go", args: [:])
        #expect(ran.ids == ["b/t"])

        // What dispatch stores itself is reused.
        _ = try await runtime.dispatch("go", args: [:])
        #expect(ran.ids == ["b/t", "b/t"])
        let proof = try #require(try await runtime.dispatch("go", args: [:]).metadata?[DispatchMetadataKey.proof] as? ResolutionProof)
        #expect(proof.decision == .cache)
    }

    @Test("dispatch racing unregisterClass never runs the removed tool afterwards")
    func concurrentUnregister() async throws {
        var lateRuns = 0
        for i in 0..<300 {
            let ran = Ran()
            let (runtime, _) = try await raceRuntime(ran: ran)
            async let first = runtime.dispatch("go", args: [:])
            async let removed: Bool = {
                // Land the unregistration at different points of the dispatch.
                for _ in 0..<(i % 12) { await Task.yield() }
                return await runtime.unregisterClass("a")
            }()
            _ = try await first
            #expect(await removed)
            #expect(await runtime.context.getTool("a/t") == nil)
            let before = ran.ids.count
            _ = try await runtime.dispatch("go", args: [:])
            if ran.ids.count > before { lateRuns += 1 }
        }
        #expect(lateRuns == 0, "a/t ran after its class was unregistered in \(lateRuns) of 300 runs")
    }

    @Test("a tool unregistered while its call is being prepared does not run, by id or by intent")
    func unregisteredDuringPreparation() async throws {
        for byId in [true, false] {
            let ran = Ran()
            let gate = Gate()
            let (runtime, _) = try await raceRuntime(ran: ran, schemaGate: gate)
            let call = Task { byId ? try await runtime.dispatchById("a/t") : try await runtime.dispatch("go", args: [:]) }
            await gate.firstArrival()  // the schema load is suspended
            #expect(await runtime.unregisterClass("a"))
            gate.open()
            let result = try await call.value
            #expect(ran.ids.isEmpty, byId ? "by id" : "by intent")
            #expect(result.isError)
            #expect(outcome(result) == DispatchOutcomeCode.unresolved.rawValue)
            #expect((result.metadata?[DispatchMetadataKey.proof] as? ResolutionProof)?.ran == nil)
        }
    }

    @Test("SW-REV-06: concurrent novel intents never embed more than maxNovelIntents")
    func rateLimitUnderConcurrency() async throws {
        let ran = Ran()
        let embedder = SlowTableEmbedder([:], delay: .milliseconds(100))
        let (runtime, _) = try await raceRuntime(
            ran: ran,
            options: RuntimeOptions(rateLimiter: SemanticRateLimiterOptions(maxNovelIntents: 2)),
            embedder: embedder
        )
        let outcomes = try await withThrowingTaskGroup(of: ResolutionOutcome.self) { group in
            for i in 0..<20 {
                group.addTask { try await runtime.resolve("novel intent number \(i)").outcome }
            }
            return try await group.reduce(into: [ResolutionOutcome]()) { $0.append($1) }
        }
        #expect(embedder.calls <= 2, "\(embedder.calls) novel intents were embedded with maxNovelIntents = 2")
        #expect(outcomes.filter { $0 == .throttled }.count == 18)
    }

    @Test("SW-REV-06: an embedding that fails gives its rate-limit slot back")
    func failedEmbeddingReleasesSlot() async throws {
        struct Broken: Error {}
        final class FlakyEmbedder: Embedder, @unchecked Sendable {
            let dimensions = 4
            private let lock = NSLock()
            private var failures = 2
            func embed(_ text: String) async throws -> [Float] {
                let fail = lock.withLock { () -> Bool in
                    guard failures > 0 else { return false }
                    failures -= 1
                    return true
                }
                if fail { throw Broken() }
                return [0, 0, 0, 1]
            }
        }
        let runtime = ToolRuntime(vectorIndex: MemoryVectorIndex(), embedder: FlakyEmbedder(),
                                  options: RuntimeOptions(rateLimiter: SemanticRateLimiterOptions(maxNovelIntents: 1)))
        await #expect(throws: Broken.self) { try await runtime.resolve("one") }
        await #expect(throws: Broken.self) { try await runtime.resolve("two") }
        #expect(try await runtime.resolve("three").outcome != .throttled)
        #expect(try await runtime.resolve("four").outcome == .throttled)
    }
}
