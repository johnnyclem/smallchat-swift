import Testing
@testable import SmallChatCore
import SmallChatEmbedding

@Suite("SelectorTable")
struct SelectorTableTests {

    private func makeTable() -> SelectorTable {
        SelectorTable(index: MemoryVectorIndex(), embedder: LocalEmbedder())
    }

    @Test("Resolving an intent does not grow the tool selector table")
    func resolveDoesNotPolluteToolSelectors() async throws {
        let table = makeTable()

        _ = try await table.resolve("search for projects in my workspace")
        _ = try await table.resolve("list all the workspaces please")
        _ = try await table.resolve("create a brand new project")

        #expect(await table.size == 0)
        #expect(await table.all().isEmpty)
    }

    @Test("An intent keeps its own embedding and identity key, even when it equals a tool's canonical")
    func resolveUsesTheIntentsOwnVector() async throws {
        let table = makeTable()
        let embedder = LocalEmbedder()
        let toolEmbedding = try await embedder.embed("search_flights: search for available flights")
        _ = try await table.register(embedding: toolEmbedding, canonical: "search:flights")

        let resolved = try await table.resolve("search flights")
        #expect(resolved.vector == (try await embedder.embed("search flights")))
        #expect(resolved.key == "search flights")
        #expect(await table.size == 1)
    }

    @Test("Resolution does not depend on intents seen before")
    func resolutionIsHistoryFree() async throws {
        let table = makeTable()
        let first = try await table.resolve("delete the logs")
        for i in 0..<20 { _ = try await table.resolve("unrelated intent number \(i)") }
        let again = try await table.resolve("delete the logs")
        #expect(first.vector == again.vector)
        #expect(first.key == again.key)
        #expect(try await table.resolve("do not delete the logs").key != first.key)
    }

    @Test("register never folds two similar tools into one selector")
    func registerKeepsToolsApart() async throws {
        let table = makeTable()
        let v: [Float] = [1, 0, 0]
        _ = try await table.register(embedding: v, canonical: "a.tool")
        _ = try await table.register(embedding: v, canonical: "b.tool")
        #expect(await table.size == 2)
    }

    @Test("searchTools orders equal quantized scores by id, whatever the registration order")
    func searchToolsTieBreak() async throws {
        let table = makeTable()
        _ = try await table.register(embedding: [0.9, 0.43588989, 0], canonical: "zeta.run")
        _ = try await table.register(embedding: [0.9, 0, 0.43588989], canonical: "alpha.run")
        let matches = try await table.searchTools([1, 0, 0], topK: 5, threshold: 0.6)
        #expect(matches.map(\.id) == ["alpha.run", "zeta.run"])
        let top1 = try await table.searchTools([1, 0, 0], topK: 1, threshold: 0.6)
        #expect(top1.map(\.id) == ["alpha.run"])
    }
}
