import Foundation
import Testing
@testable import SmallChatMemex
import SmallChatCore

@Suite("Memex compiler")
struct MemexTests {

    private func source(_ id: String, _ title: String) -> KnowledgeSource {
        KnowledgeSource(
            id: id,
            type: .markdown,
            path: "examples/\(id).md",
            title: title
        )
    }

    @Test("Compile produces sources, claims, entities, pages, and an index")
    func compileSmoke() {
        let body = """
        Alice met Bob at the cafe in Berlin.
        Bob then went to the library with Carol.
        Alice and Carol later visited the museum together.
        """
        let kb = MemexCompiler().compile([
            (source("s1", "trip-notes"), body),
        ])

        #expect(kb.sources.count == 1)
        #expect(kb.sources.first?.contentHash != nil)

        // Every Capitalised word becomes an entity.
        let entityNames = Set(kb.entities.map(\.name))
        #expect(entityNames.contains("Alice"))
        #expect(entityNames.contains("Bob"))
        #expect(entityNames.contains("Carol"))

        // One claim per non-trivial sentence.
        #expect(kb.claims.count >= 3)

        // An index page exists in addition to per-entity pages.
        #expect(kb.pages.contains { $0.slug == "index" })
        #expect(kb.pages.contains { $0.slug == "alice" })

        // Co-mention relationships exist between Alice/Bob/Carol.
        let labels = Set(kb.relationships.map(\.label))
        #expect(labels.contains("co-mentioned"))
    }

    @Test("Inbound links are backfilled when an entity references another")
    func inboundLinksBackfilled() {
        let body = "Alice met Bob. Bob met Carol."
        let kb = MemexCompiler().compile([
            (source("s1", "t"), body),
        ])
        let bobPage = kb.pages.first { $0.slug == "bob" }
        #expect(bobPage != nil)
        // Bob's page should have inbound links from Alice's and Carol's pages.
        #expect(bobPage?.inboundLinks.contains("alice") == true)
    }

    @Test("Contradiction detection flags a literal negation pair")
    func contradictionDetected() {
        let body = """
        The deploy succeeded for service Alpha.
        The deploy did not succeed for service Alpha.
        """
        let kb = MemexCompiler().compile([
            (source("s1", "deploy-log"), body),
        ])
        #expect(!kb.contradictions.isEmpty)
    }

    @Test("Resolver returns hits ranked by confidence")
    func resolverRanks() {
        let body = "Alice runs the platform team. Bob runs the database team."
        let kb = MemexCompiler().compile([
            (source("s1", "teams"), body),
        ])
        let resolver = MemexResolver(knowledgeBase: kb)
        let hits = resolver.query("Alice", limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.first?.page.title == "Alice")
        for i in 1..<hits.count {
            #expect(hits[i - 1].confidence >= hits[i].confidence)
        }
    }

    @Test("Empty query returns no hits")
    func resolverEmptyQuery() {
        let kb = MemexCompiler().compile([
            (source("s1", "teams"), "Alice runs the platform team."),
        ])
        let resolver = MemexResolver(knowledgeBase: kb)
        #expect(resolver.query("").isEmpty)
    }
}
