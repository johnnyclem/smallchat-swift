import ArgumentParser
import Foundation
import SmallChat

struct DocsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Generate Markdown documentation from a compiled artifact (format 1.0)"
    )

    @Argument(help: "Path to the compiled toolkit file")
    var file: String

    @Option(name: .shortAndLong, help: "Output Markdown file path")
    var output: String = "TOOLS.md"

    func run() async throws {
        let artifact: ArtifactV1
        do {
            artifact = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: file))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode.failure
        }

        var lines: [String] = []
        lines.append("# Tool Reference")
        lines.append("")
        lines.append("> Auto-generated from `\(URL(fileURLWithPath: file).lastPathComponent)` on \(ISO8601DateFormatter().string(from: Date()).prefix(10))")
        lines.append("")

        // Overview
        lines.append("## Overview")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append("| Total tools | \(artifact.tools.count) |")
        lines.append("| Selectors | \(artifact.selectors.count) |")
        lines.append("| Providers | \(artifact.providers.count) |")
        lines.append("| Collisions | \(artifact.collisions.count) |")
        lines.append("| Embedder | \(artifact.embedder.summary) |")
        lines.append("| Content hash | `\(artifact.contentHash)` |")
        lines.append("")

        // Tools by provider
        lines.append("## Tools by Provider")
        lines.append("")
        for providerId in artifact.providers.keys.sorted() {
            let toolIds = artifact.toolIds.filter { artifact.tools[$0]?.providerId == providerId }
            lines.append("### \(providerId) (\(toolIds.count) tools)")
            lines.append("")
            for toolId in toolIds {
                guard let tool = artifact.tools[toolId] else { continue }
                lines.append("#### `\(toolId)`")
                lines.append("")
                if !tool.description.isEmpty { lines.append(tool.description); lines.append("") }
                lines.append("- **Selector**: `\(tool.selector)`")
                lines.append("- **Transport**: `\(tool.transportType)`")
                if let annotations = tool.annotations, !annotations.isEmpty {
                    let hints = annotations.jsonValue.keys.sorted().map { "\($0): \(annotations.jsonValue[$0]!)" }
                    lines.append("- **Annotations**: \(hints.joined(separator: ", "))")
                }
                lines.append("")
            }
        }

        // Collisions
        if !artifact.collisions.isEmpty {
            lines.append("## Selector Collisions")
            lines.append("")
            for c in artifact.collisions {
                lines.append("- **\(c.selectorA)** vs **\(c.selectorB)** — similarity: \(String(format: "%.1f", c.similarity * 100))%")
                lines.append("  - \(c.hint)")
            }
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")
        try markdown.write(toFile: output, atomically: true, encoding: .utf8)
        print("Documentation generated: \(output)")
        print("  \(artifact.tools.count) tools across \(artifact.providers.count) providers")
    }
}
