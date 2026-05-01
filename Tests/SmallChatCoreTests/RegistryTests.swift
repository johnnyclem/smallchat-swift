import Foundation
import Testing
@testable import SmallChatCore

@Suite("Registry / Bundle / InstallPlan")
struct RegistryTests {

    // MARK: - InstallMethod

    @Test("InstallMethod round-trips through Codable for all four kinds")
    func installMethodRoundTrip() throws {
        let inputs: [InstallMethod] = [
            .npm(packageName: "@loom-mcp/server", command: "npx -y @loom-mcp/server"),
            .pip(packageName: "mcp-server-postgres"),
            .docker(image: "ghcr.io/foo/bar:latest", args: ["--read-only"]),
            .binary(downloadURL: "https://example.com/x", sha256: "abc123"),
        ]
        for m in inputs {
            let data = try JSONEncoder().encode(m)
            let decoded = try JSONDecoder().decode(InstallMethod.self, from: data)
            #expect(decoded == m)
        }
    }

    // MARK: - RegistryEntry decoding

    @Test("RegistryEntry decodes a real example file")
    func registryEntryDecodes() throws {
        let json = """
        {
          "id": "github",
          "name": "GitHub MCP",
          "description": "Read GitHub.",
          "version": "1.0.0",
          "license": "MIT",
          "categories": ["code", "collaboration"],
          "badges": ["read-only-by-default", "auth-required"],
          "installMethods": [
            {"kind": "npm", "packageName": "@github/github-mcp-server", "command": "npx -y @github/github-mcp-server"}
          ],
          "envVars": [
            {"name": "GITHUB_TOKEN", "description": "PAT", "required": true, "secret": true}
          ],
          "args": []
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(RegistryEntry.self, from: json)
        #expect(entry.id == "github")
        #expect(entry.categories == ["code", "collaboration"])
        #expect(entry.envVars.first?.secret == true)
        #expect(entry.installMethods.first == .npm(
            packageName: "@github/github-mcp-server",
            command: "npx -y @github/github-mcp-server"
        ))
    }

    // MARK: - On-disk examples

    @Test("All four example registry entries decode")
    func diskRegistryEntries() throws {
        let names = ["github", "slack", "postgresql", "loom"]
        for name in names {
            let url = URL(fileURLWithPath: "examples/registry/\(name).json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let entry = try JSONDecoder().decode(RegistryEntry.self, from: data)
            #expect(entry.id == name)
            #expect(!entry.installMethods.isEmpty)
        }
    }

    @Test("RegistryIndex example decodes and lists 4 entries")
    func diskRegistryIndex() throws {
        let url = URL(fileURLWithPath: "examples/registry/index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(RegistryIndex.self, from: data)
        #expect(index.entries.count == 4)
        #expect(index.entries.contains { $0.id == "loom" })
    }

    @Test("Example bundle decodes with three entries and two target clients")
    func diskBundle() throws {
        let url = URL(fileURLWithPath: "examples/registry/example-bundle.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let bundle = try JSONDecoder().decode(SmallChatBundle.self, from: data)
        #expect(bundle.name == "code-review-bundle")
        #expect(bundle.entries.count == 3)
        #expect(bundle.targetClients.count == 2)
    }

    // MARK: - InstallPlan

    @Test("InstallPlan for a registry entry orders steps: install, env prompts, compile")
    func planOrdersSteps() {
        let entry = RegistryEntry(
            id: "x",
            name: "X",
            description: "y",
            version: "0.1.0",
            installMethods: [.npm(packageName: "@x/y", command: "npx -y @x/y")],
            envVars: [
                RegistryEnvVar(name: "X_TOKEN", required: true, secret: true),
                RegistryEnvVar(name: "X_OPTIONAL", required: false),
            ]
        )
        let plan = InstallPlan.plan(for: entry)
        let kinds = plan.steps.map(\.kind)
        #expect(kinds.first == .install)
        #expect(kinds.last == .compile)
        // Required env var prompt is in the plan; optional is not.
        let envSteps = plan.steps.filter { $0.kind == .envVarPrompt }
        #expect(envSteps.count == 1)
        #expect(envSteps.first?.summary.contains("X_TOKEN") == true)
    }

    @Test("InstallPlan for a bundle includes per-entry steps and target-client wiring")
    func planForBundle() {
        let bundle = SmallChatBundle(
            name: "b",
            version: "0.1.0",
            entries: [
                RegistryEntry(
                    id: "a",
                    name: "A",
                    description: "a",
                    version: "1.0.0",
                    installMethods: [.npm(packageName: "@a/a")]
                ),
                RegistryEntry(
                    id: "b",
                    name: "B",
                    description: "b",
                    version: "1.0.0",
                    installMethods: [.docker(image: "x:latest")]
                ),
            ],
            compiledArtifactPath: "bundles/x.toolkit.json",
            targetClients: [
                SmallChatBundle.TargetClient(
                    id: "claude-code",
                    displayName: "Claude Code",
                    configPath: "~/.claude/mcp.json",
                    snippet: "{}"
                )
            ]
        )

        let plan = InstallPlan.plan(for: bundle)
        // Two install steps (one per entry) + one wiring + one compile-artifact step
        let installSteps = plan.steps.filter { $0.kind == .install }
        let wiringSteps = plan.steps.filter { $0.kind == .clientWiring }
        let compileSteps = plan.steps.filter { $0.kind == .compile }
        #expect(installSteps.count == 2)
        #expect(wiringSteps.count == 1)
        #expect(compileSteps.count >= 1)
    }
}
