import ArgumentParser
import Foundation
import SmallChat

struct MemexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memex",
        abstract: "Knowledge-base compiler: turn text sources into a cross-referenced wiki",
        subcommands: [
            Compile.self,
            Query.self,
            Lint.self,
            Inspect.self,
            Export.self,
        ]
    )

    // MARK: - compile

    struct Compile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compile",
            abstract: "Compile one or more text sources into a KnowledgeBase JSON file"
        )

        @Argument(help: "Source files (any text-like file -- markdown / txt)")
        var paths: [String]

        @Option(name: .shortAndLong, help: "Output JSON path")
        var output: String = "memex.json"

        func run() async throws {
            guard !paths.isEmpty else {
                throw ValidationError("memex compile requires at least one source path")
            }

            var inputs: [(KnowledgeSource, String)] = []
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let body = try String(contentsOf: url, encoding: .utf8)
                let id = (path as NSString).lastPathComponent
                let src = KnowledgeSource(
                    id: id,
                    type: detectType(path),
                    path: path,
                    title: id
                )
                inputs.append((src, body))
            }

            let kb = MemexCompiler().compile(inputs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(kb)
            try data.write(to: URL(fileURLWithPath: output))

            print("Compiled \(kb.sources.count) source(s)")
            print("  \(kb.claims.count) claims")
            print("  \(kb.entities.count) entities")
            print("  \(kb.pages.count) pages")
            if !kb.contradictions.isEmpty {
                print("  \(kb.contradictions.count) contradictions detected")
            }
            print("Output: \(output)")
        }
    }

    // MARK: - query

    struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "query",
            abstract: "Look up an entity in a compiled KnowledgeBase"
        )

        @Argument(help: "Path to a memex.json compiled KnowledgeBase")
        var knowledgeBase: String

        @Argument(help: "Query text (entity name or topic)")
        var query: String

        @Option(help: "Max results to return")
        var limit: Int = 5

        func run() async throws {
            let kb = try loadKB(knowledgeBase)
            let resolver = MemexResolver(knowledgeBase: kb)
            let hits = resolver.query(query, limit: limit)
            if hits.isEmpty {
                print("No results.")
                return
            }
            for hit in hits {
                print(String(format: "  [%.2f] %@", hit.confidence, hit.page.title))
            }
        }
    }

    // MARK: - lint

    struct Lint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lint",
            abstract: "Run health checks against a compiled KnowledgeBase"
        )

        @Argument(help: "Path to a memex.json compiled KnowledgeBase")
        var knowledgeBase: String

        func run() async throws {
            let kb = try loadKB(knowledgeBase)

            var issues: [String] = []

            // Orphans: entity pages with no claims.
            for page in kb.pages where page.pageType == .entity && page.claimIds.isEmpty {
                issues.append("orphan entity page: \(page.title)")
            }
            // Stale: sources not ingested in the last 30 days (when timestamps available).
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            for src in kb.sources {
                guard let stamp = src.lastIngested, let date = formatter.date(from: stamp) else { continue }
                if date < thirtyDaysAgo { issues.append("stale source: \(src.id) (last ingested \(stamp))") }
            }
            // Contradictions surface as issues.
            for c in kb.contradictions {
                issues.append("contradiction: \(c.claimAId) vs \(c.claimBId) -- \(c.reason)")
            }

            if issues.isEmpty {
                print("No issues found.")
            } else {
                print("\(issues.count) issue(s):")
                for issue in issues {
                    print("  - \(issue)")
                }
            }
        }
    }

    // MARK: - inspect

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Print summary stats for a compiled KnowledgeBase"
        )

        @Argument(help: "Path to a memex.json compiled KnowledgeBase")
        var knowledgeBase: String

        func run() async throws {
            let kb = try loadKB(knowledgeBase)
            print("KnowledgeBase \(kb.version)")
            print("  compiled at:    \(kb.compiledAt)")
            print("  sources:        \(kb.sources.count)")
            print("  claims:         \(kb.claims.count)")
            print("  entities:       \(kb.entities.count)")
            print("  pages:          \(kb.pages.count)")
            print("  relationships:  \(kb.relationships.count)")
            print("  contradictions: \(kb.contradictions.count)")
        }
    }

    // MARK: - export

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export wiki pages as a directory of Markdown files"
        )

        @Argument(help: "Path to a memex.json compiled KnowledgeBase")
        var knowledgeBase: String

        @Option(name: .shortAndLong, help: "Output directory")
        var output: String = "memex-wiki"

        func run() async throws {
            let kb = try loadKB(knowledgeBase)
            let dir = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            for page in kb.pages {
                let header = "# \(page.title)\n\n"
                let body = page.content.isEmpty ? "_(no content)_" : page.content
                let outbound = page.outboundLinks.isEmpty ? "" : "\n\n## See also\n\n" +
                    page.outboundLinks.map { "- [\($0)](\($0).md)" }.joined(separator: "\n")
                let text = header + body + outbound + "\n"
                let url = dir.appendingPathComponent("\(page.slug).md")
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            print("Exported \(kb.pages.count) page(s) to \(output)/")
        }
    }
}

// MARK: - shared helpers

private func detectType(_ path: String) -> SourceType {
    let lower = path.lowercased()
    if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return .markdown }
    if lower.hasSuffix(".html") { return .html }
    if lower.hasSuffix(".csv") { return .csv }
    if lower.hasSuffix(".jsonl") { return .jsonl }
    return .plainText
}

private func loadKB(_ path: String) throws -> KnowledgeBase {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(KnowledgeBase.self, from: data)
}
