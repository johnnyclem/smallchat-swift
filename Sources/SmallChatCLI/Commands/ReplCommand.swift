import ArgumentParser
import Foundation
import SmallChat

struct ReplCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repl",
        abstract: "Start an interactive shell for querying tool resolution (nothing runs)"
    )

    @Argument(help: "Path to the compiled toolkit file")
    var file: String

    func run() async throws {
        let toolkit = try await loadArtifactRuntime(file)
        let artifact = toolkit.artifact
        let catalog = MCPToolCatalog(artifact: artifact)

        print("smallchat repl v\(SmallChatVersion.current)")
        print("Loaded \(artifact.tools.count) tools (\(artifact.selectors.count) selectors) from \(artifact.providers.count) providers")
        print("Type an intent to resolve, or :help for commands.\n")

        // REPL loop
        while true {
            print("smallchat> ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                print("\nGoodbye.")
                break
            }

            if line.isEmpty { continue }

            if line.hasPrefix(":") {
                let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
                let cmd = String(parts[0])

                switch cmd {
                case "help", "h":
                    print("\nCommands:")
                    print("  :help, :h         Show this help")
                    print("  :providers, :p    List all providers")
                    print("  :selectors, :s    List all selectors")
                    print("  :stats            Show artifact stats")
                    print("  :quit, :q         Exit the REPL")
                    print("\nType any natural language intent to resolve.\n")

                case "providers", "p":
                    print("\nProviders:")
                    for providerId in artifact.providers.keys.sorted() {
                        let count = artifact.tools.values.filter { $0.providerId == providerId }.count
                        print("  \(providerId): \(count) tools")
                    }
                    print("")

                case "selectors", "s":
                    print("\nSelectors:")
                    for canonical in artifact.selectors.keys.sorted() {
                        let selector = artifact.selectors[canonical]!
                        print("  \(canonical) -> \(selector.toolId) (\(selector.kind))")
                    }
                    print("")

                case "stats":
                    print("\nArtifact:")
                    print("  Format:     \(ARTIFACT_FORMAT_VERSION)")
                    print("  Embedder:   \(artifact.embedder.summary)")
                    print("  Tools:      \(artifact.tools.count)")
                    print("  Selectors:  \(artifact.selectors.count)")
                    print("  Providers:  \(artifact.providers.count)")
                    print("  Collisions: \(artifact.collisions.count)")
                    print("  Hash:       \(artifact.contentHash)")
                    print("")

                case "quit", "q":
                    print("Goodbye.")
                    return

                default:
                    print("Unknown command: :\(cmd). Type :help for available commands.\n")
                }
                continue
            }

            // Resolve intent (nothing runs)
            do {
                let resolution = try await toolkit.runtime.resolve(line)
                print("")
                print(describeResolution(resolution, catalog: catalog))
                print("")
            } catch {
                print("  Error: \(error)\n")
            }
        }
    }
}
