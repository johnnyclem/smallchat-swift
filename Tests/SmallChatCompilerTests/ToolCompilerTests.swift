import Foundation
import Testing
@testable import SmallChatCompiler
import SmallChatCore
import SmallChatEmbedding

/// The 1.0 compiler semantics shared with @smallchat/core: tools are
/// registered, never merged; duplicates are an error unless allowed; one
/// selector (and one alias phrase) belongs to exactly one tool.
@Suite("ToolCompiler 1.0 semantics")
struct ToolCompilerTests {

    private func tool(_ name: String, _ description: String, provider: String, hints: CompilerHint? = nil) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: JSONSchemaType(type: "object"),
            providerId: provider,
            transportType: .mcp,
            compilerHints: hints
        )
    }

    private func provider(_ id: String, _ tools: [ToolDefinition]) -> ProviderManifest {
        ProviderManifest(id: id, name: id, tools: tools, transportType: .mcp)
    }

    private func compiler(_ options: CompilerOptions = CompilerOptions()) -> ToolCompiler {
        ToolCompiler(embedder: LocalEmbedder(dimensions: 64), vectorIndex: MemoryVectorIndex(), options: options)
    }

    /// The same tool published by two providers embeds identically.
    private var twins: [ProviderManifest] {
        [
            provider("github", [tool("search", "Search issues and pull requests", provider: "github")]),
            provider("gitlab", [tool("search", "Search issues and pull requests", provider: "gitlab")]),
        ]
    }

    @Test("two distinct tools that embed alike are a compile error, not a merge")
    func duplicatesRefused() async throws {
        do {
            _ = try await compiler().compile(twins)
            Issue.record("compiled a toolkit whose intents cannot tell two tools apart")
        } catch let error as DuplicateToolError {
            #expect(error.pairs.map { [$0.toolA, $0.toolB] } == [["github/search", "gitlab/search"]])
            #expect(error.threshold == 0.95)
            #expect(error.description.contains("--allow-duplicates"))
        }
    }

    @Test("allowDuplicates keeps every tool and reports the pair")
    func duplicatesAllowed() async throws {
        let result = try await compiler(CompilerOptions(allowDuplicates: true)).compile(twins)
        #expect(result.tools.map(\.id) == ["github/search", "gitlab/search"])
        #expect(result.toolCount == 2)
        #expect(result.uniqueSelectorCount == 2)
        #expect(result.mergedCount == 0)
        #expect(result.duplicates.count == 1)
        #expect(result.duplicates.first?.selectorA == "github.search")
        #expect(result.duplicates.first?.selectorB == "gitlab.search")
        #expect((result.duplicates.first?.similarity ?? 0) >= 0.95)
        #expect(result.dispatchTables["github"]?["github.search"]?.toolId == "github/search")
        #expect(result.dispatchTables["gitlab"]?["gitlab.search"]?.toolId == "gitlab/search")
    }

    @Test("an alias phrase declared by two tools is refused, however it is spelled")
    func sharedAliasRefused() async throws {
        let manifests = [
            provider("notes", [
                tool("create_note", "Create a note", provider: "notes", hints: CompilerHint(aliases: ["Jot  It Down"])),
                tool("append_note", "Append text to a note", provider: "notes", hints: CompilerHint(aliases: ["jot it down"])),
            ]),
        ]
        do {
            _ = try await compiler(CompilerOptions(allowDuplicates: true)).compile(manifests)
            Issue.record("two tools share one alias phrase")
        } catch let error as SelectorConflictError {
            #expect(error.message.contains("notes/append_note"))
            #expect(error.message.contains("notes/create_note"))
        }
    }

    @Test("one tool may repeat its own alias; it gets one selector")
    func repeatedOwnAlias() async throws {
        let manifests = [
            provider("notes", [
                tool("create_note", "Create a note", provider: "notes", hints: CompilerHint(aliases: ["jot it down", "jot it down"])),
            ]),
        ]
        let result = try await compiler().compile(manifests)
        #expect(result.tools.first?.aliases == ["notes.create_note~alias~jot_it_down"])
        #expect(result.uniqueSelectorCount == 2)
    }

    @Test("two tools pinned to one selector are refused")
    func pinClashRefused() async throws {
        let manifests = [
            provider("a", [tool("one", "First tool about apples", provider: "a", hints: CompilerHint(pinnedSelector: "shared.pin"))]),
            provider("b", [tool("two", "Second tool about bicycles", provider: "b", hints: CompilerHint(pinnedSelector: "shared.pin"))]),
        ]
        await #expect(throws: SelectorConflictError.self) {
            _ = try await compiler().compile(manifests)
        }
    }

    @Test("a tool name declared twice by one provider is refused")
    func repeatedToolIdRefused() async throws {
        let manifests = [
            provider("notes", [
                tool("create_note", "Create a note", provider: "notes"),
                tool("create_note", "Create a note, again", provider: "notes"),
            ]),
        ]
        await #expect(throws: SelectorConflictError.self) {
            _ = try await compiler(CompilerOptions(allowDuplicates: true)).compile(manifests)
        }
    }
}
