import ArgumentParser
import Foundation
import SmallChat

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup wizard — auto-detect MCP servers and compile a toolkit"
    )

    @Flag(name: .long, help: "Skip interactive prompts and use defaults")
    var noInteractive: Bool = false

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "tools.toolkit.json"

    func run() async throws {
        print("\nsmallchat setup\n")
        print("This wizard will help you discover MCP server configurations")
        print("and compile them into a smallchat toolkit.\n")

        let prompt = InteractivePrompt(interactive: !noInteractive)

        // Probe for loom-mcp -- the headlining 0.5.0 integration. We only
        // surface its presence; the user wires it via their MCP client
        // config (the example bundle has a snippet) or `smallchat install`.
        switch LoomDetection.probe() {
        case .present:
            print("loom-mcp launcher (npx) detected on PATH.")
            print("  bundled manifest: examples/loom-mcp-manifest.json (\(LoomMCPClient.knownToolNames.count) tools)")
        case .missing:
            print("loom-mcp launcher (npx) not found on PATH.")
            print("  install with: npm i -g @loom-mcp/server")
        case .unknown:
            print("loom-mcp: PATH not inspectable in this environment; skipping probe.")
        }
        print("")

        // Step 1: Discovery
        let discoveredConfigs = try await discoverConfigs(prompt: prompt)

        guard !discoveredConfigs.isEmpty else {
            print("\nNo MCP server configurations found.")
            print("Run \"smallchat init\" to scaffold a new project, or")
            print("run \"smallchat compile --source <path>\" to compile from a manifest.\n")
            throw ExitCode.failure
        }

        // Step 2: Parse MCP servers from discovered configs
        var allManifests: [ProviderManifest] = []
        var sourceConfigPath: String?

        for config in discoveredConfigs {
            print("\nProcessing: \(config.path)")
            sourceConfigPath = sourceConfigPath ?? config.path

            let manifests = try extractManifests(from: config.path)
            if manifests.isEmpty {
                print("  No MCP servers found in this file.")
            } else {
                print("  Found \(manifests.count) MCP server(s):")
                for m in manifests {
                    print("    - \(m.id) (\(m.tools.count) tools)")
                }
                allManifests.append(contentsOf: manifests)
            }
        }

        guard !allManifests.isEmpty else {
            print("\nNo valid MCP servers found in the discovered configurations.")
            throw ExitCode.failure
        }

        let totalTools = allManifests.reduce(0) { $0 + $1.tools.count }
        print("\nDiscovered \(allManifests.count) MCP server(s) with \(totalTools) total tool(s).")

        // Step 3: Compile
        let shouldCompile = prompt.interactive
            ? try await prompt.confirm("Compile these into a toolkit?", default: true)
            : true

        guard shouldCompile else {
            print("Setup cancelled.")
            return
        }

        print("\nCompiling...")
        let embedder = LocalEmbedder()
        let vectorIndex = MemoryVectorIndex()
        let compiler = ToolCompiler(embedder: embedder, vectorIndex: vectorIndex)

        print("  Embedding \(totalTools) tools...")
        print("  Model: hash-based (v0.0.1 placeholder)")

        let result = try await compiler.compile(allManifests)

        print("  Selectors generated: \(result.toolCount)")
        print("  Unique selectors: \(result.uniqueSelectorCount)")
        if result.mergedCount > 0 {
            print("  \(result.mergedCount) tools merged as semantically equivalent")
        }
        if !result.collisions.isEmpty {
            print("  Selector collisions: \(result.collisions.count)")
            for collision in result.collisions {
                print("    WARNING: \(collision.selectorA) ↔ \(collision.selectorB) (cosine: \(String(format: "%.2f", collision.similarity)))")
            }
        }

        // Serialize
        let artifact = serializeResult(result, manifests: allManifests)
        let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
        let outputURL = URL(fileURLWithPath: output)
        try data.write(to: outputURL)

        print("\nToolkit written to: \(output)")
        print("  - \(result.uniqueSelectorCount) selectors")
        print("  - \(result.toolCount) tools")
        print("  - \(result.dispatchTables.count) providers")

        // Step 4: Optionally replace MCP config
        if let configPath = sourceConfigPath, prompt.interactive {
            let shouldReplace = try await prompt.confirm(
                "Replace mcpServers in \(configPath) with a smallchat server entry?",
                default: false
            )
            if shouldReplace {
                try replaceMcpServers(configPath: configPath, toolkitPath: output)
            } else {
                print("\nTo serve your toolkit manually:")
                print("  smallchat serve --source \(output)")
            }
        } else {
            print("\nTo serve your toolkit:")
            print("  smallchat serve --source \(output)")
        }

        print("\nSetup complete!\n")
    }

    // MARK: - Discovery

    private func discoverConfigs(prompt: InteractivePrompt) async throws -> [DiscoveredConfig] {
        if !prompt.interactive {
            return autoDetect()
        }

        print("How would you like to find MCP server configurations?\n")
        let choices = [
            "Auto-detect (scan standard locations)",
            "Paste a file path",
            "Select a CLI tool",
        ]

        let choice = try await prompt.choose("Discovery method:", choices: choices)

        switch choice {
        case 0:
            return autoDetect()
        case 1:
            return try await pasteFilePath(prompt: prompt)
        case 2:
            return try await selectCliTool(prompt: prompt)
        default:
            return autoDetect()
        }
    }

    private func autoDetect() -> [DiscoveredConfig] {
        print("\nScanning standard locations...")
        let paths = autoDetectPaths()
        var found: [DiscoveredConfig] = []

        for (label, path) in paths {
            let expanded = expandTilde(path)
            if FileManager.default.fileExists(atPath: expanded) {
                print("  ✓ \(label): \(expanded)")
                found.append(DiscoveredConfig(path: expanded, label: label))
            }
        }

        if found.isEmpty {
            print("  No configurations found in standard locations.")
        }

        return found
    }

    private func pasteFilePath(prompt: InteractivePrompt) async throws -> [DiscoveredConfig] {
        let path = try await prompt.ask("Enter the path to your MCP config file:")
        let expanded = expandTilde(path.trimmingCharacters(in: .whitespacesAndNewlines))

        guard FileManager.default.fileExists(atPath: expanded) else {
            print("File not found: \(expanded)")
            return []
        }

        return [DiscoveredConfig(path: expanded, label: "user-provided")]
    }

    private func selectCliTool(prompt: InteractivePrompt) async throws -> [DiscoveredConfig] {
        let tools = cliTools()
        let toolNames = tools.map(\.name)

        let choice = try await prompt.choose("Select a CLI tool:", choices: toolNames)
        guard choice >= 0 && choice < tools.count else { return [] }

        let tool = tools[choice]
        print("\nSearching for \(tool.name) configurations...")

        var found: [DiscoveredConfig] = []
        for path in tool.paths {
            let expanded = expandTilde(path)
            if FileManager.default.fileExists(atPath: expanded) {
                print("  ✓ Found: \(expanded)")
                found.append(DiscoveredConfig(path: expanded, label: tool.name))
            }
        }

        if found.isEmpty {
            print("  No \(tool.name) configuration found.")
        }

        return found
    }

    // MARK: - Config Paths

    private func autoDetectPaths() -> [(label: String, path: String)] {
        [
            ("Claude Code", "~/.claude/settings.json"),
            ("Claude Desktop", "~/.config/Claude/claude_desktop_config.json"),
            ("Claude Desktop (macOS)", "~/Library/Application Support/Claude/claude_desktop_config.json"),
            ("VS Code", "~/.vscode/settings.json"),
            ("MCP config", "~/.mcp.json"),
            ("Gemini CLI", "~/.gemini/settings.json"),
            ("OpenCode", "~/.opencode/config.json"),
        ]
    }

    private func cliTools() -> [CliTool] {
        [
            CliTool(name: "Claude Code", paths: [
                "~/.claude/settings.json",
                "~/.mcp.json",
            ]),
            CliTool(name: "Claude Desktop", paths: [
                "~/.config/Claude/claude_desktop_config.json",
                "~/Library/Application Support/Claude/claude_desktop_config.json",
            ]),
            CliTool(name: "Gemini CLI", paths: [
                "~/.gemini/settings.json",
            ]),
            CliTool(name: "OpenCode", paths: [
                "~/.opencode/config.json",
            ]),
            CliTool(name: "Codex", paths: [
                "~/.codex/config.json",
            ]),
        ]
    }

    // MARK: - MCP Server Extraction

    private func extractManifests(from path: String) throws -> [ProviderManifest] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Try to find mcpServers at top level or nested
        let mcpServers: [String: Any]?
        if let servers = json["mcpServers"] as? [String: Any] {
            mcpServers = servers
        } else if let nested = json["mcp"] as? [String: Any],
                  let servers = nested["mcpServers"] as? [String: Any] {
            mcpServers = servers
        } else {
            mcpServers = nil
        }

        guard let servers = mcpServers else { return [] }

        var manifests: [ProviderManifest] = []
        for (serverId, serverConfig) in servers {
            guard let config = serverConfig as? [String: Any] else { continue }

            let transportType: TransportType
            if config["command"] != nil {
                transportType = .mcp
            } else if config["url"] != nil {
                transportType = .rest
            } else {
                transportType = .local
            }

            // Extract tools if present, otherwise create a placeholder
            var tools: [ToolDefinition] = []
            if let toolList = config["tools"] as? [[String: Any]] {
                for toolDict in toolList {
                    if let name = toolDict["name"] as? String,
                       let desc = toolDict["description"] as? String {
                        tools.append(ToolDefinition(
                            name: name,
                            description: desc,
                            inputSchema: JSONSchemaType(type: "object"),
                            providerId: serverId,
                            transportType: transportType
                        ))
                    }
                }
            }

            // If no tools listed, create a single placeholder tool from the server entry
            if tools.isEmpty {
                let command = config["command"] as? String ?? serverId
                let args = config["args"] as? [String] ?? []
                let description = args.isEmpty
                    ? "MCP server: \(command)"
                    : "MCP server: \(command) \(args.joined(separator: " "))"

                tools.append(ToolDefinition(
                    name: serverId,
                    description: description,
                    inputSchema: JSONSchemaType(type: "object"),
                    providerId: serverId,
                    transportType: transportType
                ))
            }

            let endpoint: String?
            if let url = config["url"] as? String {
                endpoint = url
            } else if let command = config["command"] as? String {
                let args = config["args"] as? [String] ?? []
                endpoint = ([command] + args).joined(separator: " ")
            } else {
                endpoint = nil
            }

            manifests.append(ProviderManifest(
                id: serverId,
                name: serverId,
                tools: tools,
                transportType: transportType,
                endpoint: endpoint
            ))
        }

        return manifests
    }

    // MARK: - Config Replacement

    private func replaceMcpServers(configPath: String, toolkitPath: String) throws {
        let backupPath = configPath + ".backup"
        let fm = FileManager.default

        // Backup original
        if fm.fileExists(atPath: backupPath) {
            try fm.removeItem(atPath: backupPath)
        }
        try fm.copyItem(atPath: configPath, toPath: backupPath)
        print("  Backed up original to: \(backupPath)")

        // Read and modify
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("  Failed to parse config as JSON.")
            return
        }

        let absoluteToolkit = URL(fileURLWithPath: toolkitPath).standardizedFileURL.path

        let smallchatServer: [String: Any] = [
            "command": "smallchat",
            "args": ["serve", "--source", absoluteToolkit],
        ]

        // Replace at the correct nesting level
        if json["mcpServers"] != nil {
            json["mcpServers"] = ["smallchat": smallchatServer]
        } else if var mcp = json["mcp"] as? [String: Any], mcp["mcpServers"] != nil {
            mcp["mcpServers"] = ["smallchat": smallchatServer]
            json["mcp"] = mcp
        } else {
            json["mcpServers"] = ["smallchat": smallchatServer]
        }

        let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: configPath))
        print("  Updated \(configPath) with smallchat server entry.")
    }

    // MARK: - Serialization (matches CompileCommand output format)

    private func serializeResult(_ result: CompilationResult, manifests: [ProviderManifest]) -> [String: Any] {
        var selectors: [String: Any] = [:]
        for (key, sel) in result.selectors {
            selectors[key] = [
                "canonical": sel.canonical,
                "parts": sel.parts,
                "arity": sel.arity,
                "vector": sel.vector,
            ] as [String: Any]
        }

        var dispatchTables: [String: Any] = [:]
        for (providerId, table) in result.dispatchTables {
            var methods: [String: Any] = [:]
            for (canonical, imp) in table {
                methods[canonical] = [
                    "providerId": imp.providerId,
                    "toolName": imp.toolName,
                    "transportType": imp.transportType.rawValue,
                ] as [String: Any]
            }
            dispatchTables[providerId] = methods
        }

        return [
            "version": "0.5.0",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "embedding": [
                "model": "hash-based",
                "dimensions": 384,
                "embedderType": "local",
            ],
            "stats": [
                "toolCount": result.toolCount,
                "uniqueSelectorCount": result.uniqueSelectorCount,
                "mergedCount": result.mergedCount,
                "providerCount": result.dispatchTables.count,
                "collisionCount": result.collisions.count,
            ],
            "selectors": selectors,
            "dispatchTables": dispatchTables,
            "collisions": result.collisions.map { c in
                [
                    "selectorA": c.selectorA,
                    "selectorB": c.selectorB,
                    "similarity": c.similarity,
                    "hint": c.hint,
                ] as [String: Any]
            },
        ] as [String: Any]
    }

    // MARK: - Helpers

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        return path
    }
}

// MARK: - Supporting Types

private struct DiscoveredConfig {
    let path: String
    let label: String
}

private struct CliTool {
    let name: String
    let paths: [String]
}

// MARK: - Interactive Prompt

private struct InteractivePrompt {
    let interactive: Bool

    func ask(_ question: String) async throws -> String {
        guard interactive else { return "" }
        print(question)
        print("> ", terminator: "")
        guard let line = readLine() else {
            throw SetupError.readlineClosed
        }
        return line
    }

    func choose(_ question: String, choices: [String]) async throws -> Int {
        guard interactive else { return 0 }
        print(question)
        for (i, choice) in choices.enumerated() {
            print("  \(i + 1)) \(choice)")
        }
        print("> ", terminator: "")
        guard let line = readLine(),
              let num = Int(line.trimmingCharacters(in: .whitespaces)),
              num >= 1 && num <= choices.count else {
            print("Invalid selection, defaulting to option 1.")
            return 0
        }
        return num - 1
    }

    func confirm(_ question: String, default defaultValue: Bool = true) async throws -> Bool {
        guard interactive else { return defaultValue }
        let hint = defaultValue ? "[Y/n]" : "[y/N]"
        print("\(question) \(hint) ", terminator: "")
        guard let line = readLine() else {
            return defaultValue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return defaultValue }
        return trimmed == "y" || trimmed == "yes"
    }
}

private enum SetupError: Error, CustomStringConvertible {
    case readlineClosed

    var description: String {
        switch self {
        case .readlineClosed:
            return "Input stream closed unexpectedly"
        }
    }
}
