import Foundation
import Testing
import SmallChatCore
import SmallChatCompiler
import SmallChatEmbedding
import SmallChatMCP
import SmallChatRuntime

/// spec/artifact (format 1.0): the golden artifact is accepted and its
/// content hash recomputed; every negative fixture is refused (rules 1-4);
/// every embedder fingerprint that differs in one field is refused (rule
/// 5); and the Swift compiler reproduces the golden artifact from its
/// manifest.
@Suite("Conformance: artifact format 1.0 (spec/artifact)")
struct ArtifactFixtureTests {
    static let index = try! SpecFixtures.json("artifact/fixtures/invalid/index.json")

    static func minimal() throws -> ArtifactV1 {
        try ArtifactV1.parse(SpecFixtures.data("artifact/fixtures/minimal.v1.json"), source: "minimal.v1.json")
    }

    @Test("the format version is 1.0")
    func formatVersion() {
        #expect(ARTIFACT_FORMAT_VERSION == "1.0")
    }

    @Test("minimal.v1.json is accepted and its content hash recomputes")
    func goldenAccepted() throws {
        let artifact = try Self.minimal()
        let recorded = try SpecFixtures.json("artifact/fixtures/minimal.v1.json")["contentHash"]?.stringValue
        #expect(artifact.contentHash == recorded)
        #expect(try ArtifactV1.computeContentHash(artifact.json) == recorded)
        #expect(artifact.embedder == .hash(dims: 16))
        #expect(artifact.toolIds == ["notes/create_note", "notes/delete_note"])
        #expect(artifact.selectors(of: "notes/create_note").map(\.canonical) == [
            "notes.create_note", "notes.create_note~alias~jot_something_down",
        ])
        #expect(artifact.tools["notes/delete_note"]?.annotations?.destructiveHint == true)
        #expect(artifact.providers["notes"]?.launch == .stdio(command: "notes-mcp", args: ["--stdio"], env: ["NOTES_TOKEN"]))
    }

    @Test("the serialized form reads back to the same artifact")
    func roundTrip() throws {
        let artifact = try Self.minimal()
        let again = try ArtifactV1.parse(artifact.serialized())
        #expect(again.contentHash == artifact.contentHash)
        #expect(again.json == artifact.json)
    }

    @Test("every negative fixture is refused", arguments: Self.index["artifacts"]!.arrayValue)
    func invalidRefused(_ entry: AnyCodableValue) throws {
        let file = try #require(entry["file"]?.stringValue)
        let rule = try #require(entry["rule"]?.doubleValue)
        let data = try SpecFixtures.data("artifact/fixtures/invalid/\(file)")
        do {
            _ = try ArtifactV1.parse(data, source: file)
            Issue.record("\(file) was accepted (breaks rule \(Int(rule)))")
        } catch let error as ArtifactVersionError {
            #expect(rule == 1, "\(file): \(error)")
        } catch let error as ArtifactFormatError {
            #expect(rule != 1, "\(file): \(error)")
        }
    }

    /// An embedder that declares a given fingerprint.
    private struct DeclaredEmbedder: Embedder {
        let fingerprint: EmbedderFingerprint?
        var dimensions: Int { fingerprint?.dims ?? 0 }
        func embed(_ text: String) async throws -> [Float] { [Float](repeating: 0, count: dimensions) }
    }

    @Test("an embedder that differs in any one fingerprint field is refused", arguments: Self.index["embedderMismatches"]!["cases"]!.arrayValue)
    func embedderMismatch(_ entry: AnyCodableValue) throws {
        let artifact = try Self.minimal()
        let data = try JSONEncoder().encode(try #require(entry["fingerprint"]))
        let fingerprint = try JSONDecoder().decode(EmbedderFingerprint.self, from: data)
        #expect(fingerprint != artifact.embedder)
        #expect(throws: EmbedderMismatchError.self, "\(entry["field"]?.stringValue ?? "")") {
            try artifact.assertEmbedder(DeclaredEmbedder(fingerprint: fingerprint))
        }
    }

    @Test("the matching embedder is accepted; one without a fingerprint is not")
    func embedderMatch() throws {
        let artifact = try Self.minimal()
        try artifact.assertEmbedder(LocalEmbedder(dimensions: 16))
        #expect(throws: EmbedderMismatchError.self) { try artifact.assertEmbedder(LocalEmbedder()) }
        #expect(throws: EmbedderMismatchError.self) { try artifact.assertEmbedder(DeclaredEmbedder(fingerprint: nil)) }
    }

    @Test("compiling minimal.manifest.json with the hash embedder at 16 dims reproduces minimal.v1.json")
    func goldenPairReproduces() async throws {
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: SpecFixtures.data("artifact/fixtures/minimal.manifest.json"))
        let embedder = LocalEmbedder(dimensions: 16)
        let result = try await ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex()).compile([manifest])
        let built = try ArtifactV1.build(result: result, manifests: [manifest], embedder: try #require(embedder.fingerprint))
        let golden = try Self.minimal()
        #expect(try canonicalJSON(.dict(built.json)) == canonicalJSON(.dict(golden.json)))
        #expect(built.contentHash == golden.contentHash)
    }

    @Test("a TypeScript-compiled artifact loads into a runtime and resolves under the policy")
    func goldenResolves() async throws {
        let toolkit = try await MCPToolkit.make(artifact: try Self.minimal())
        // The alias phrase embeds exactly as its selector: EXACT.
        let alias = try await toolkit.runtime.resolve("jot something down")
        #expect(alias.outcome == .resolved)
        #expect(alias.chosen == "notes/create_note")
        #expect(alias.proof.artifactHash == toolkit.artifact.contentHash)
        #expect(alias.proof.embedder == .hash(dims: 16))
        // The destructive tool runs only at EXACT similarity.
        let exact = try await toolkit.runtime.resolve("delete_note: Permanently delete a note by id")
        #expect(exact.chosen == "notes/delete_note")
        let near = try await toolkit.runtime.resolve("permanently delete the note")
        #expect(near.chosen == nil)
        #expect(toolkit.unavailable.map(\.toolId) == ["notes/create_note", "notes/delete_note"])
    }

    @Test("a 0.x artifact is refused with a request to recompile")
    func preOneRefused() async throws {
        let data = try SpecFixtures.data("artifact/fixtures/invalid/pre-1.0.json")
        #expect(throws: ArtifactVersionError.self) { _ = try ArtifactV1.parse(data) }
    }
}
