import ArgumentParser
import Foundation
import SmallChat

struct ExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain how an intent resolves: every candidate's score and tier against the thresholds, the guards, and what the judge would be asked (nothing runs)",
        discussion: """
        Like resolve, but with the thresholds and guards the decision was made against, each \
        candidate's distance from the tier boundaries, and the judge: which one is configured, \
        whether a live dispatch would ask it and among which tools. Explain never calls a judge \
        and never learns; the resolution it prints is what a dispatch decides without one.
        """
    )

    @Argument(help: "Path to the compiled toolkit file (artifact format 1.0)")
    var file: String

    @Argument(help: "Natural language intent to explain")
    var intent: String

    @OptionGroup var judgeOptions: JudgeOptions

    @Flag(help: "Print the explanation as JSON")
    var json: Bool = false

    func run() async throws {
        let toolkit = try await loadArtifactRuntime(file, options: try judgeOptions.runtimeOptions())
        let explanation = try await toolkit.runtime.explain(intent)
        if json {
            print(try prettyJSON(explanation.jsonValue), terminator: "")
        } else {
            print(formatExplanation(explanation))
        }
    }
}
