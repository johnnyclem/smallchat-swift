import Foundation
import Testing
@testable import SmallChatCompiler
import SmallChatCore
import SmallChatEmbedding

@Suite("LoomManifest")
struct LoomManifestTests {

    @Test("ProviderManifest decodes provider-level compilerHints + description")
    func decodeProviderHints() throws {
        let json = """
        {
          "id": "loom",
          "name": "Loom MCP",
          "transportType": "mcp",
          "description": "AST-aware code-context compiler.",
          "compilerHints": {
            "namespacePrefix": "loom",
            "semanticContext": "code-aware tools over a local AST index"
          },
          "tools": []
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: json)
        #expect(manifest.id == "loom")
        #expect(manifest.description == "AST-aware code-context compiler.")
        #expect(manifest.compilerHints?.namespacePrefix == "loom")
        #expect(manifest.compilerHints?.semanticContext == "code-aware tools over a local AST index")
    }

    @Test("ToolDefinition decodes per-tool compilerHints with aliases")
    func decodeToolHints() throws {
        let json = """
        {
          "name": "loom_find_importers",
          "description": "Reverse-dependency lookup.",
          "providerId": "loom",
          "transportType": "mcp",
          "inputSchema": { "type": "object" },
          "compilerHints": {
            "selectorHint": "Find callers / importers of a symbol.",
            "aliases": ["find callers of foo", "who imports this"]
          }
        }
        """.data(using: .utf8)!

        let tool = try JSONDecoder().decode(ToolDefinition.self, from: json)
        #expect(tool.compilerHints?.selectorHint == "Find callers / importers of a symbol.")
        #expect(tool.compilerHints?.aliases == ["find callers of foo", "who imports this"])
    }

    @Test("embeddingText is <name>: <description> plus the selector hint; aliases embed on their own")
    func embeddingTextIncludesHints() async throws {
        let manifest = ProviderManifest(
            id: "loom",
            name: "Loom MCP",
            tools: [
                ToolDefinition(
                    name: "loom_find_importers",
                    description: "Reverse-dependency lookup.",
                    inputSchema: JSONSchemaType(type: "object"),
                    providerId: "loom",
                    transportType: .mcp,
                    compilerHints: CompilerHint(
                        selectorHint: "Find callers / importers of a symbol.",
                        aliases: ["find callers of foo", "who imports this"]
                    )
                )
            ],
            transportType: .mcp,
            description: "AST-aware code-context compiler.",
            compilerHints: ProviderCompilerHints(
                namespacePrefix: "loom",
                semanticContext: "code-aware tools over a local AST index"
            )
        )

        let parsed = parseMCPManifest(manifest)
        #expect(parsed.count == 1)

        // As @smallchat/core 1.0: the tool's own selectorHint wins over the
        // provider's (semanticContext); aliases become their own selectors.
        #expect(parsed[0].embeddingText == "loom_find_importers: Reverse-dependency lookup. Find callers / importers of a symbol.")

        let result = try await ToolCompiler(embedder: LocalEmbedder(dimensions: 32), vectorIndex: MemoryVectorIndex()).compile([manifest])
        #expect(result.tools.first?.selector == "loom.loom_find_importers")
        #expect(result.tools.first?.aliases == [
            "loom.loom_find_importers~alias~find_callers_of_foo",
            "loom.loom_find_importers~alias~who_imports_this",
        ])
        #expect(result.dispatchTables["loom"]?.count == 3)
    }

    @Test("a provider's semanticContext is the selector hint of tools without their own")
    func providerHintFallback() {
        let manifest = ProviderManifest(
            id: "loom",
            name: "Loom MCP",
            tools: [ToolDefinition(name: "loom_x", description: "X.", inputSchema: JSONSchemaType(type: "object"), providerId: "loom", transportType: .mcp)],
            transportType: .mcp,
            compilerHints: ProviderCompilerHints(semanticContext: "code-aware tools")
        )
        #expect(parseMCPManifest(manifest)[0].embeddingText == "loom_x: X. code-aware tools")
    }

    @Test("parseMCPManifest honors compilerHints.exclude = true")
    func excludedToolIsDropped() {
        let manifest = ProviderManifest(
            id: "loom",
            name: "Loom MCP",
            tools: [
                ToolDefinition(
                    name: "loom_keep",
                    description: "Kept tool.",
                    inputSchema: JSONSchemaType(type: "object"),
                    providerId: "loom",
                    transportType: .mcp
                ),
                ToolDefinition(
                    name: "loom_drop",
                    description: "Excluded tool.",
                    inputSchema: JSONSchemaType(type: "object"),
                    providerId: "loom",
                    transportType: .mcp,
                    compilerHints: CompilerHint(exclude: true)
                ),
            ],
            transportType: .mcp
        )

        let parsed = parseMCPManifest(manifest)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "loom_keep")
    }

    @Test("On-disk examples/loom-mcp-manifest.json decodes and yields 28 parsed tools")
    func diskManifestRoundTrip() throws {
        // The package root is the working directory when tests run from `swift test`.
        let url = URL(fileURLWithPath: "examples/loom-mcp-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Skip when invoked outside the package root (e.g. from an IDE).
            return
        }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: data)

        #expect(manifest.id == "loom")
        #expect(manifest.compilerHints?.namespacePrefix == "loom")
        #expect(manifest.tools.count == 28)

        let parsed = parseMCPManifest(manifest)
        #expect(parsed.count == 28)

        // Aliases are their own selectors, not folded into the embedding text.
        let importers = parsed.first { $0.name == "loom_find_importers" }
        #expect(importers != nil)
        #expect(importers?.compilerHints?.aliases?.contains("find callers of foo") == true)
        #expect(importers?.embeddingText.contains("find callers of foo") == false)
    }
}
