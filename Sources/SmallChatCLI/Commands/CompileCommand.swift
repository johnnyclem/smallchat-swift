import ArgumentParser
import Foundation
import SmallChat

struct CompileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile",
        abstract: "Compile tool definitions from MCP server manifests into an artifact (format 1.0)"
    )

    @Option(name: .shortAndLong, help: "Source directory or manifest file")
    var source: String?

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "tools.toolkit.json"

    @Flag(help: "Enable semantic overload generation")
    var semanticOverloads: Bool = false

    @Option(help: "Collision threshold (0.0–1.0)")
    var collisionThreshold: Double = 0.89

    @Option(help: "Distinct tools that embed at or above this cosine similarity are duplicates (an error unless --allow-duplicates)")
    var duplicateThreshold: Double = 0.95

    @Flag(help: "Keep duplicate tools (both are compiled and listed under duplicates) instead of failing")
    var allowDuplicates: Bool = false

    @Option(help: "Dimensions of the hash embedder")
    var dims: Int = 384

    @Flag(help: "Treat selector collisions as compile errors")
    var strict: Bool = false

    func run() async throws {
        let sourcePath = source ?? FileManager.default.currentDirectoryPath
        print("Compiling from \(sourcePath)...")

        // Find manifest files
        let manifests = try loadManifests(from: sourcePath)
        guard !manifests.isEmpty else {
            print("No valid manifests found.")
            throw ExitCode.failure
        }

        print("Found \(manifests.count) manifest(s)")

        let embedder = LocalEmbedder(dimensions: dims)
        let options = CompilerOptions(
            collisionThreshold: collisionThreshold,
            duplicateThreshold: duplicateThreshold,
            allowDuplicates: allowDuplicates,
            generateSemanticOverloads: semanticOverloads
        )
        let compiler = ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex(), options: options)

        let toolCount = manifests.reduce(0) { $0 + $1.tools.count }
        print("\nEmbedding \(toolCount) tools...")
        print("  Embedder: \(embedder.fingerprint!.summary)")

        let result: CompilationResult
        do {
            result = try await compiler.compile(manifests)
        } catch let error as DuplicateToolError {
            print("\nERROR: \(error)")
            throw ExitCode(2)
        } catch let error as SelectorConflictError {
            print("\nERROR: \(error)")
            throw ExitCode(2)
        }

        print("  Tools: \(result.toolCount)")
        print("  Selectors: \(result.uniqueSelectorCount) (tools and aliases; tools are never merged)")
        if !result.duplicates.isEmpty {
            print("  Duplicates kept (--allow-duplicates): \(result.duplicates.count)")
            for pair in result.duplicates {
                print("    \(pair.toolA) <-> \(pair.toolB) (cosine \(String(format: "%.3f", pair.similarity)))")
            }
        }

        print("\nLinking...")
        print("  Dispatch tables: \(result.dispatchTables.count)")

        if !result.collisions.isEmpty {
            let label = strict ? "ERROR" : "WARNING"
            print("  Selector collisions: \(result.collisions.count)")
            for collision in result.collisions {
                print("    \(label): \(collision.selectorA) and \(collision.selectorB) (cosine: \(String(format: "%.2f", collision.similarity)))")
                print("      \(collision.hint)")
            }
            if strict {
                throw ExitCode(2)
            }
        }

        let artifact = try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
        try artifact.write(to: URL(fileURLWithPath: output))

        print("\nOutput: \(output) (artifact format \(ARTIFACT_FORMAT_VERSION))")
        print("  - \(artifact.tools.count) tools")
        print("  - \(artifact.selectors.count) selectors")
        print("  - \(artifact.providers.count) providers")
        print("  - contentHash \(artifact.contentHash)")
    }

    private func loadManifests(from path: String) throws -> [ProviderManifest] {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            print("Path not found: \(path)")
            return []
        }

        if isDir.boolValue {
            // Scan directory for JSON files
            guard let enumerator = fm.enumerator(atPath: path) else { return [] }
            var manifests: [ProviderManifest] = []
            while let file = enumerator.nextObject() as? String {
                guard file.hasSuffix(".json") else { continue }
                let fullPath = (path as NSString).appendingPathComponent(file)
                if let manifest = try? loadManifest(from: fullPath) {
                    manifests.append(manifest)
                    print("  \(manifest.id): \(manifest.tools.count) tools")
                }
            }
            return manifests.sorted { $0.id < $1.id }
        } else {
            // Single file
            if let manifest = try? loadManifest(from: path) {
                print("  \(manifest.id): \(manifest.tools.count) tools")
                return [manifest]
            }
            return []
        }
    }

    private func loadManifest(from path: String) throws -> ProviderManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ProviderManifest.self, from: data)
    }
}
