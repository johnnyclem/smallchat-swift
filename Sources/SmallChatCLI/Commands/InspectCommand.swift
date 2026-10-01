import ArgumentParser
import Foundation
import SmallChat

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a compiled artifact (format 1.0); it is validated first"
    )

    @Argument(help: "Path to the compiled toolkit file")
    var file: String

    @Flag(help: "Show all selectors")
    var selectors: Bool = false

    @Flag(help: "Show providers and their tools")
    var providers: Bool = false

    @Flag(help: "Show selector collisions and duplicates")
    var collisions: Bool = false

    @Flag(help: "Show the embedder fingerprint")
    var embeddings: Bool = false

    func run() async throws {
        let artifact: ArtifactV1
        do {
            artifact = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: file))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode.failure
        }

        print("ToolKit artifact: \(file)")
        print("Format: \(ARTIFACT_FORMAT_VERSION)")
        print("Content hash: \(artifact.contentHash) (verified)")
        print("Stats:")
        print("  Tools: \(artifact.tools.count)")
        print("  Selectors: \(artifact.selectors.count)")
        print("  Providers: \(artifact.providers.count)")
        print("  Collisions: \(artifact.collisions.count)")
        print("  Duplicates: \(artifact.duplicates.count)")

        if embeddings {
            let e = artifact.embedder
            print("\nEmbedder:")
            print("  Kind: \(e.kind)")
            print("  Model: \(e.model)")
            print("  Model SHA-256: \(e.modelSha256 ?? "none")")
            print("  Dimensions: \(e.dims)")
            print("  Max length: \(e.maxLength.map(String.init) ?? "none")")
            print("  Pooling: \(e.pooling)")
            print("  Normalized: \(e.normalize)")
        }

        if selectors {
            print("\nSelectors:")
            for canonical in artifact.selectors.keys.sorted() {
                let selector = artifact.selectors[canonical]!
                print("  \(canonical) -> \(selector.toolId) (\(selector.kind))")
            }
        }

        if providers {
            print("\nProviders:")
            for providerId in artifact.providers.keys.sorted() {
                let tools = artifact.toolIds.filter { artifact.tools[$0]?.providerId == providerId }
                let launch = artifact.providers[providerId]?.launch.map { $0.isStdio ? "stdio \($0.command ?? "")" : "\($0.transport) \($0.url ?? "")" } ?? "no launch spec"
                print("  \(providerId): \(tools.count) tools (\(launch))")
                for toolId in tools { print("    - \(toolId)") }
            }
        }

        if collisions {
            print("\nCollisions:")
            if artifact.collisions.isEmpty { print("  None") }
            for c in artifact.collisions {
                print("  WARNING: \(c.selectorA) <-> \(c.selectorB) (\(String(format: "%.1f", c.similarity * 100))%)")
                print("    \(c.hint)")
            }
            if !artifact.duplicates.isEmpty {
                print("\nDuplicates (compiled with --allow-duplicates):")
                for d in artifact.duplicates {
                    print("  \(d.toolA) <-> \(d.toolB) (cosine \(String(format: "%.3f", d.similarity)))")
                }
            }
        }
    }
}
