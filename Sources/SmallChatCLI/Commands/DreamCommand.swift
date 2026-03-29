import ArgumentParser
import SmallChatDream

struct DreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dream",
        abstract: "Memory-driven tool re-compilation using Claude session insights",
        discussion: """
        Reads Claude memory files and session logs to discover tool usage
        patterns, then re-compiles the tool manifest with informed priorities.

        Steps:
          1. Scan memory files (CLAUDE.md) for tool mentions and sentiment
          2. Parse session logs for tool usage statistics
          3. Prioritize tools based on gathered intelligence
          4. Run a fresh compile with priority hints
          5. Manage artifact versioning with rollback support
        """
    )

    @Option(name: .long, help: "Source manifest path or directory")
    var source: String?

    @Option(name: .long, help: "Output artifact path")
    var output: String = "tools.toolkit.json"

    @Option(name: .long, help: "Path to dream config file")
    var config: String?

    @Flag(name: .long, help: "Auto-promote the new artifact (replace current)")
    var auto: Bool = false

    @Flag(name: .long, help: "Analyze only -- don't compile or write artifacts")
    var dryRun: Bool = false

    @Option(name: .long, help: "Embedder type (local or onnx)")
    var embedder: String = "local"

    @Option(name: .long, help: "Maximum artifact versions to retain")
    var maxVersions: Int = 5

    @Option(name: .long, help: "Path to Claude session log directory")
    var logDir: String?

    func run() async throws {
        let configOverrides = DreamConfig(
            autoDream: auto,
            memoryPaths: [],
            logDir: logDir ?? "",
            maxRetainedVersions: maxVersions,
            outputPath: output,
            sourcePath: source,
            embedder: embedder == "onnx" ? .onnx : .local
        )

        let options = CompileLatestOptions(
            configOverrides: configOverrides,
            configPath: config,
            dryRun: dryRun
        )

        let result = try await compileLatest(options)

        if dryRun {
            print("\nDry run complete. No artifacts were written.")
        } else if result.autoPromoted {
            print("\nDream complete. Artifact promoted to: \(output)")
        } else if let artifactPath = result.artifactPath {
            print("\nDream complete. Pending artifact at: \(artifactPath)")
        }
    }
}
