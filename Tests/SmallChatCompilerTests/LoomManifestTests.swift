import Foundation
import Testing
@testable import SmallChatCompiler
import SmallChatCore

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

    @Test("parseMCPManifest folds provider + tool hints into embeddingText")
    func embeddingTextIncludesHints() {
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

        let text = parsed[0].embeddingText
        #expect(text.contains("loom_find_importers"))
        #expect(text.contains("Reverse-dependency lookup."))
        #expect(text.contains("Find callers / importers of a symbol."))
        #expect(text.contains("find callers of foo"))
        #expect(text.contains("code-aware tools over a local AST index"))
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

        // Spot-check that the alias text made it into the embedding string.
        let importers = parsed.first { $0.name == "loom_find_importers" }
        #expect(importers != nil)
        #expect(importers?.embeddingText.contains("find callers of foo") == true)
    }
}
