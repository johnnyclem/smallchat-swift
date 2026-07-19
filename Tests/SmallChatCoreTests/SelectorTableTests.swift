import Testing
@testable import SmallChatCore
import SmallChatEmbedding

@Suite("SelectorTable")
struct SelectorTableTests {

    private func makeTable(intentCacheCapacity: Int = 2048) -> SelectorTable {
        SelectorTable(
            index: MemoryVectorIndex(),
            embedder: LocalEmbedder(),
            intentCacheCapacity: intentCacheCapacity
        )
    }

    @Test("Resolving an intent does not grow the tool selector table")
    func resolveDoesNotPolluteToolSelectors() async throws {
        let table = makeTable()

        #expect(await table.size == 0)

        _ = try await table.resolve("search for projects in my workspace")
        _ = try await table.resolve("list all the workspaces please")
        _ = try await table.resolve("create a brand new project")

        // Three distinct intents resolved, none of which is a compiled tool --
        // `selectors`/`all()` (the tool space) must remain empty.
        #expect(await table.size == 0)
        #expect(await table.all().isEmpty)
    }

    @Test("Resolving the same intent twice reuses the cached selector")
    func resolveCachesRepeatIntent() async throws {
        let table = makeTable()

        let first = try await table.resolve("search for projects in my workspace")
        let second = try await table.resolve("search for projects in my workspace")

        #expect(first.canonical == second.canonical)
        #expect(await table.cachedIntentCount == 1)
    }

    @Test("Intent cache is bounded and evicts least-recently-used entries")
    func intentCacheIsBounded() async throws {
        let table = makeTable(intentCacheCapacity: 4)

        for i in 0..<20 {
            _ = try await table.resolve("do something distinct number \(i)")
        }

        // Never exceeds the configured capacity no matter how many distinct
        // intents are resolved.
        #expect(await table.cachedIntentCount <= 4)
    }

    @Test("Interned tool selectors are unaffected by unrelated intent resolution")
    func internedToolSelectorsSurviveIntentChurn() async throws {
        let table = makeTable(intentCacheCapacity: 2)
        let embedder = LocalEmbedder()

        let toolEmbedding = try await embedder.embed("create_project: create a new project")
        let toolSelector = try await table.intern(embedding: toolEmbedding, canonical: "create:project")

        // Push enough distinct intents through to overflow the (tiny) intent cache.
        for i in 0..<10 {
            _ = try await table.resolve("completely unrelated churn intent \(i)")
        }

        #expect(await table.size == 1)
        #expect(await table.get("create:project")?.canonical == toolSelector.canonical)
    }

    @Test("Resolving an intent that matches a tool's own canonical text returns that tool selector")
    func resolveMatchesRegisteredToolSelector() async throws {
        let table = makeTable()
        let embedder = LocalEmbedder()

        let toolEmbedding = try await embedder.embed("search_flights: search for available flights")
        _ = try await table.intern(embedding: toolEmbedding, canonical: "search:flights")

        // Same exact canonical form the tool was registered under -- exact fast path.
        let resolved = try await table.resolve("search flights")
        #expect(resolved.canonical == "search:flights")

        // Tool space is untouched by the resolve() call.
        #expect(await table.size == 1)
    }
}
