import SwiftUI
import SmallChat

struct DiscoveryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MCP Discovery")
                    .font(.largeTitle.bold())

                Text("Auto-detect MCP server configurations from standard locations on your machine.")
                    .foregroundStyle(.secondary)

                LoomStatus()

                Divider()

                // Scan Button
                HStack {
                    Button(action: { scanConfigs() }) {
                        Label("Scan Standard Locations", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isScanning)

                    if state.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                // Discovered Configs
                if !state.discoveredConfigs.isEmpty {
                    GroupBox("Discovered Configurations") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($state.discoveredConfigs) { $config in
                                HStack {
                                    Toggle(isOn: $config.selected) {
                                        VStack(alignment: .leading) {
                                            Text(config.label)
                                                .fontWeight(.medium)
                                            Text(config.path)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }

                    // Compile Selected
                    HStack {
                        Button(action: { Task { await compileSelected() } }) {
                            Label("Compile Selected", systemImage: "hammer")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.discoveredConfigs.filter(\.selected).isEmpty || state.isScanning)
                    }
                }

                // Log
                if !state.discoveryLog.isEmpty {
                    LogView(state.discoveryLog, title: "Discovery Output")
                        .frame(minHeight: 150, maxHeight: 300)
                }

                // Standard Locations Reference
                GroupBox("Standard Locations") {
                    VStack(alignment: .leading, spacing: 4) {
                        LocationRow(label: "Claude Code", path: "~/.claude/settings.json")
                        LocationRow(label: "Claude Desktop", path: "~/Library/Application Support/Claude/claude_desktop_config.json")
                        LocationRow(label: "Claude Desktop (Linux)", path: "~/.config/Claude/claude_desktop_config.json")
                        LocationRow(label: "VS Code", path: "~/.vscode/settings.json")
                        LocationRow(label: "MCP Config", path: "~/.mcp.json")
                        LocationRow(label: "Gemini CLI", path: "~/.gemini/settings.json")
                        LocationRow(label: "OpenCode", path: "~/.opencode/config.json")
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func scanConfigs() {
        appState.isScanning = true
        appState.discoveredConfigs = []
        appState.discoveryLog = ["Scanning standard locations..."]

        let searchPaths: [(label: String, path: String)] = [
            ("Claude Code", "~/.claude/settings.json"),
            ("Claude Desktop", "~/.config/Claude/claude_desktop_config.json"),
            ("Claude Desktop (macOS)", "~/Library/Application Support/Claude/claude_desktop_config.json"),
            ("VS Code", "~/.vscode/settings.json"),
            ("MCP Config", "~/.mcp.json"),
            ("Gemini CLI", "~/.gemini/settings.json"),
            ("OpenCode", "~/.opencode/config.json"),
        ]

        let fm = FileManager.default

        for (label, path) in searchPaths {
            let expanded = expandTilde(path)
            if fm.fileExists(atPath: expanded) {
                appState.discoveredConfigs.append(
                    DiscoveredConfigItem(label: label, path: expanded, selected: true)
                )
                appState.discoveryLog.append("  Found: \(label) at \(expanded)")
            }
        }

        if appState.discoveredConfigs.isEmpty {
            appState.discoveryLog.append("  No configurations found in standard locations.")
        } else {
            appState.discoveryLog.append("Found \(appState.discoveredConfigs.count) configuration(s).")
        }

        appState.isScanning = false
    }

    @MainActor
    private func compileSelected() async {
        let selected = appState.discoveredConfigs.filter(\.selected)
        guard !selected.isEmpty else { return }

        appState.isScanning = true
        appState.discoveryLog.append("")
        appState.discoveryLog.append("Processing \(selected.count) configuration(s)...")

        var allManifests: [ProviderManifest] = []

        for config in selected {
            appState.discoveryLog.append("Processing: \(config.path)")
            if let manifests = try? extractMCPManifests(from: config.path) {
                if manifests.isEmpty {
                    appState.discoveryLog.append("  No MCP servers found.")
                } else {
                    appState.discoveryLog.append("  Found \(manifests.count) MCP server(s):")
                    for m in manifests {
                        appState.discoveryLog.append("    - \(m.id) (\(m.tools.count) tools)")
                    }
                    allManifests.append(contentsOf: manifests)
                }
            }
        }

        guard !allManifests.isEmpty else {
            appState.discoveryLog.append("No valid MCP servers found.")
            appState.isScanning = false
            return
        }

        let totalTools = allManifests.reduce(0) { $0 + $1.tools.count }
        appState.discoveryLog.append("")
        appState.discoveryLog.append("Compiling \(allManifests.count) server(s), \(totalTools) tool(s)...")

        do {
            let embedder = LocalEmbedder()
            let vectorIndex = MemoryVectorIndex()
            let compiler = ToolCompiler(embedder: embedder, vectorIndex: vectorIndex)

            let result = try await compiler.compile(allManifests)

            appState.discoveryLog.append("  Selectors: \(result.uniqueSelectorCount)")
            appState.discoveryLog.append("  Tools: \(result.toolCount)")
            appState.discoveryLog.append("  Providers: \(result.dispatchTables.count)")

            if !result.collisions.isEmpty {
                for collision in result.collisions {
                    appState.discoveryLog.append("  WARNING: \(collision.selectorA) <-> \(collision.selectorB)")
                }
            }

            // Save artifact
            let outputPath = "tools.toolkit.json"
            let artifact = serializeCompilationResult(result, manifests: allManifests)
            let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: outputPath))

            appState.discoveryLog.append("")
            appState.discoveryLog.append("Toolkit written to: \(outputPath)")
            appState.discoveryLog.append("Discovery and compilation complete!")

            // Pre-populate compiler and server paths
            appState.compilerOutputPath = outputPath
            appState.serverSourcePath = outputPath

        } catch {
            appState.discoveryLog.append("ERROR: \(error.localizedDescription)")
        }

        appState.isScanning = false
    }

    // MARK: - Helpers

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        return path
    }

    private func extractMCPManifests(from path: String) throws -> [ProviderManifest] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

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

    private func serializeCompilationResult(_ result: CompilationResult, manifests: [ProviderManifest]) -> [String: Any] {
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
            "version": "0.2.0",
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
}

// MARK: - Supporting Views

struct LocationRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack {
            Text(label)
                .fontWeight(.medium)
                .frame(width: 160, alignment: .leading)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
