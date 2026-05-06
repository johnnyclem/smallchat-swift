import Testing
import Foundation
@testable import SmallChatCompiler
import SmallChatCore
import SmallChatEmbedding

@Suite("AppCompiler")
struct AppCompilerTests {

    private func makeCompiler() -> AppCompiler {
        AppCompiler(embedder: LocalEmbedder(), vectorIndex: MemoryVectorIndex())
    }

    // MARK: - Parse uiResourceUri

    @Test("parseUiResourceUri: inline HTML stored in embeddedHTML")
    func parseUiResourceUriInline() async throws {
        let compiler = makeCompiler()
        let manifest = AppManifest(
            id: "my-app",
            name: "My App",
            uiResourceUri: "<html><body>Hello</body></html>"
        )
        let result = try await compiler.compile([manifest])
        #expect(result.appArtifact != nil)
        #expect(result.appArtifact?.embeddedHTML["ui://my-app/index.html"] == "<html><body>Hello</body></html>")
    }

    @Test("no uiResourceUri produces empty embeddedHTML")
    func linkNoUI() async throws {
        let compiler = makeCompiler()
        let manifest = AppManifest(id: "bare-app", name: "Bare App")
        let result = try await compiler.compile([manifest])
        #expect(result.appArtifact?.embeddedHTML.isEmpty == true)
    }

    // MARK: - Embed

    @Test("embed: component selectors interned for each ComponentDefinition")
    func embedComponentSelectors() async throws {
        let compiler = makeCompiler()
        let manifest = AppManifest(
            id: "calc",
            name: "Calculator",
            uiResourceUri: "<html/>",
            components: [
                ComponentDefinition(name: "display", description: "numeric display"),
                ComponentDefinition(name: "keypad", description: "digit buttons"),
            ]
        )
        let result = try await compiler.compile([manifest])
        guard let artifact = result.appArtifact else {
            Issue.record("appArtifact should not be nil")
            return
        }
        let classData = artifact.appClasses["calc"]
        #expect(classData != nil)
        // Entry point + 2 components = at least 3 selectors
        #expect((classData?.componentSelectors.count ?? 0) >= 3)
    }

    // MARK: - Link

    @Test("link: AppClass entries populated in appArtifact")
    func linkAppClassEntries() async throws {
        let compiler = makeCompiler()
        let manifests = [
            AppManifest(id: "app-a", name: "App A", uiResourceUri: "<html/>"),
            AppManifest(id: "app-b", name: "App B", uiResourceUri: "<html/>"),
        ]
        let result = try await compiler.compile(manifests)
        guard let artifact = result.appArtifact else {
            Issue.record("appArtifact should not be nil")
            return
        }
        #expect(artifact.appClasses["app-a"] != nil)
        #expect(artifact.appClasses["app-b"] != nil)
        #expect(artifact.appCount == 2)
    }

    // MARK: - Emit

    @Test("emit: CompilationResult.appArtifact non-nil after compile")
    func emitAppArtifact() async throws {
        let compiler = makeCompiler()
        let manifest = AppManifest(id: "my-app", name: "My App", uiResourceUri: "<html/>")
        let result = try await compiler.compile([manifest])
        #expect(result.appArtifact != nil)
        #expect(result.appArtifact?.appCount == 1)
    }

    // MARK: - Integration smoke test

    @Test("integration: compile manifest with mocked uiResourceUri → appArtifact populated")
    func integrationExamplesManifests() async throws {
        // Create a manifest that mirrors what loom-mcp-manifest would produce
        let loomManifest = AppManifest(
            id: "loom",
            name: "Loom MCP",
            uiResourceUri: "<html><body>Loom UI</body></html>",
            components: [
                ComponentDefinition(name: "code-viewer", description: "view source code"),
                ComponentDefinition(name: "diff-panel", description: "view code diffs"),
            ],
            version: "1.0.0"
        )

        let compiler = makeCompiler()
        let result = try await compiler.compile([loomManifest])

        guard let artifact = result.appArtifact else {
            Issue.record("appArtifact should not be nil")
            return
        }
        #expect(artifact.appClasses["loom"] != nil)
        #expect(artifact.embeddedHTML["ui://loom/index.html"] == "<html><body>Loom UI</body></html>")
        #expect(artifact.appCount == 1)
    }
}
