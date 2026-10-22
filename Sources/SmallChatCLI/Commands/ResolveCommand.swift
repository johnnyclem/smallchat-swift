import ArgumentParser
import Foundation
import SmallChat

struct ResolveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Show how an intent resolves against a compiled artifact (nothing runs)",
        discussion: """
        Prints the runtime's decision: the outcome (resolved, needs-disambiguation, \
        unresolved), tier, decision code, the chosen tool id, the ranked candidates and \
        the proof digest. With --judge, the shortlist judge decides near-ties as it would in \
        serve. This is the same resolution serve's smallchat_resolve tool and \
        an intent dispatch make; nothing is executed.
        """
    )

    @Argument(help: "Path to the compiled toolkit file (artifact format 1.0)")
    var file: String

    @Argument(help: "Natural language intent to resolve")
    var intent: String

    @OptionGroup var judgeOptions: JudgeOptions

    @Flag(help: "Print the resolution proof as JSON")
    var json: Bool = false

    func run() async throws {
        let toolkit = try await loadArtifactRuntime(file, options: try judgeOptions.runtimeOptions())
        let resolution = try await toolkit.runtime.resolve(intent)
        if json {
            print(try prettyJSON(resolution.proof.jsonValue), terminator: "")
        } else {
            print(describeResolution(resolution, catalog: MCPToolCatalog(artifact: toolkit.artifact)))
        }
    }
}
