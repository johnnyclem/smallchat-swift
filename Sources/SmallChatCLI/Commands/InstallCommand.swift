import ArgumentParser
import Foundation
import SmallChat

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Render an install plan for a registry entry or bundle",
        discussion: """
        Reads a RegistryEntry or SmallChatBundle JSON file and prints the
        ordered InstallPlan it would execute. By default this is a dry run
        -- nothing is written to disk and no install commands are spawned.
        Use --json to emit the plan as machine-readable JSON.
        """
    )

    @Argument(help: "Path to a RegistryEntry or SmallChatBundle JSON file")
    var path: String

    @Flag(help: "Emit the InstallPlan as JSON instead of human-readable text")
    var json: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let plan = try buildPlan(from: data)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(plan)
            if let s = String(data: jsonData, encoding: .utf8) {
                print(s)
            }
            return
        }

        renderHuman(plan)
    }

    private func buildPlan(from data: Data) throws -> InstallPlan {
        let decoder = JSONDecoder()
        if let bundle = try? decoder.decode(SmallChatBundle.self, from: data) {
            return InstallPlan.plan(for: bundle)
        }
        if let entry = try? decoder.decode(RegistryEntry.self, from: data) {
            return InstallPlan.plan(for: entry)
        }
        throw ValidationError("\(path) is neither a RegistryEntry nor a SmallChatBundle")
    }

    private func renderHuman(_ plan: InstallPlan) {
        print("Install plan: \(plan.bundleName)")
        print("Generated:    \(plan.createdAt)")
        print("Steps:        \(plan.steps.count)")
        print("")
        for (i, step) in plan.steps.enumerated() {
            print("  \(i + 1). [\(step.kind.rawValue)] \(step.summary)")
            if let detail = step.detail {
                print("     \(detail)")
            }
        }
        print("")
        print("(dry run -- no install commands executed)")
    }
}
