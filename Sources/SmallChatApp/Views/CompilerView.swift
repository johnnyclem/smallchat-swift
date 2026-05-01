import SwiftUI
import UniformTypeIdentifiers
import SmallChat

struct CompilerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Tool Compiler")
                    .font(.largeTitle.bold())

                Text("Compile tool definitions from MCP server manifests into a semantic dispatch artifact.")
                    .foregroundStyle(.secondary)

                Divider()

                // Source & Output
                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Source directory or manifest file", text: $state.compilerSourcePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                chooseSource()
                            }
                        }
                        HStack {
                            TextField("Output path", text: $state.compilerOutputPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                chooseOutput()
                            }
                        }
                    }
                    .padding(4)
                }

                // Compiler Options
                GroupBox("Compiler Options") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Collision Threshold:")
                                .frame(width: 180, alignment: .leading)
                            Slider(value: $state.collisionThreshold, in: 0.5...1.0, step: 0.01)
                            Text(String(format: "%.2f", state.collisionThreshold))
                                .monospacedDigit()
                                .frame(width: 40)
                        }

                        HStack {
                            Text("Deduplication Threshold:")
                                .frame(width: 180, alignment: .leading)
                            Slider(value: $state.deduplicationThreshold, in: 0.5...1.0, step: 0.01)
                            Text(String(format: "%.2f", state.deduplicationThreshold))
                                .monospacedDigit()
                                .frame(width: 40)
                        }

                        Toggle("Generate Semantic Overloads", isOn: $state.generateSemanticOverloads)
                    }
                    .padding(4)
                }

                // Compile Button
                HStack {
                    Button(action: { Task { await compile() } }) {
                        Label("Compile", systemImage: "hammer")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.compilerSourcePath.isEmpty || state.isCompiling)

                    if state.isCompiling {
                        ProgressView()
                            .controlSize(.small)
                        Text("Compiling...")
                            .foregroundStyle(.secondary)
                    }
                }

                // Results
                if state.lastToolCount > 0 {
                    GroupBox("Results") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Text("Tools:").fontWeight(.medium)
                                Text("\(state.lastToolCount)")
                            }
                            GridRow {
                                Text("Unique Selectors:").fontWeight(.medium)
                                Text("\(state.lastSelectorCount)")
                            }
                            GridRow {
                                Text("Merged:").fontWeight(.medium)
                                Text("\(state.lastMergedCount)")
                            }
                            GridRow {
                                Text("Providers:").fontWeight(.medium)
                                Text("\(state.lastProviderCount)")
                            }
                            GridRow {
                                Text("Collisions:").fontWeight(.medium)
                                Text("\(state.lastCollisionCount)")
                                    .foregroundStyle(state.lastCollisionCount > 0 ? .orange : .primary)
                            }
                        }
                        .padding(4)
                    }
                }

                // Log Output
                if !state.compilerLog.isEmpty {
                    LogView(state.compilerLog, title: "Compiler Output")
                        .frame(minHeight: 150, maxHeight: 300)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func chooseSource() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select source directory or manifest file"
        if panel.runModal() == .OK, let url = panel.url {
            appState.compilerSourcePath = url.path
        }
        #endif
    }

    private func chooseOutput() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tools.toolkit.json"
        panel.title = "Save compiled artifact"
        if panel.runModal() == .OK, let url = panel.url {
            appState.compilerOutputPath = url.path
        }
        #endif
    }

    @MainActor
    private func compile() async {
        appState.isCompiling = true
        appState.compilerLog = []
        appState.compilerLog.append("Compiling from \(appState.compilerSourcePath)...")

        do {
            let manifests = try loadManifests(from: appState.compilerSourcePath)
            guard !manifests.isEmpty else {
                appState.compilerLog.append("No valid manifests found.")
                appState.isCompiling = false
                return
            }

            appState.compilerLog.append("Found \(manifests.count) manifest(s)")
            let totalTools = manifests.reduce(0) { $0 + $1.tools.count }
            appState.compilerLog.append("Embedding \(totalTools) tools...")

            let embedder = LocalEmbedder()
            let vectorIndex = MemoryVectorIndex()
            let options = CompilerOptions(
                collisionThreshold: appState.collisionThreshold,
                deduplicationThreshold: appState.deduplicationThreshold,
                generateSemanticOverloads: appState.generateSemanticOverloads
            )

            let compiler = ToolCompiler(embedder: embedder, vectorIndex: vectorIndex, options: options)
            let result = try await compiler.compile(manifests)

            appState.lastToolCount = result.toolCount
            appState.lastSelectorCount = result.uniqueSelectorCount
            appState.lastMergedCount = result.mergedCount
            appState.lastProviderCount = result.dispatchTables.count
            appState.lastCollisionCount = result.collisions.count

            appState.compilerLog.append("Selectors generated: \(result.toolCount)")
            appState.compilerLog.append("Unique selectors: \(result.uniqueSelectorCount)")

            if result.mergedCount > 0 {
                appState.compilerLog.append("\(result.mergedCount) tools merged as semantically equivalent")
            }

            for collision in result.collisions {
                appState.compilerLog.append("WARNING: \(collision.selectorA) <-> \(collision.selectorB) (cosine: \(String(format: "%.2f", collision.similarity)))")
                appState.compilerLog.append("  \(collision.hint)")
            }

            // Serialize output
            let artifact = serializeResult(result, manifests: manifests)
            let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            let outputURL = URL(fileURLWithPath: appState.compilerOutputPath)
            try data.write(to: outputURL)

            appState.compilerLog.append("")
            appState.compilerLog.append("Output written to: \(appState.compilerOutputPath)")
            appState.compilerLog.append("Compilation complete!")

        } catch {
            appState.compilerLog.append("ERROR: \(error.localizedDescription)")
        }

        appState.isCompiling = false
    }

    // MARK: - Manifest Loading

    private func loadManifests(from path: String) throws -> [ProviderManifest] {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return []
        }

        if isDir.boolValue {
            guard let enumerator = fm.enumerator(atPath: path) else { return [] }
            var manifests: [ProviderManifest] = []
            while let file = enumerator.nextObject() as? String {
                guard file.hasSuffix(".json") else { continue }
                let fullPath = (path as NSString).appendingPathComponent(file)
                if let manifest = try? loadSingleManifest(from: fullPath) {
                    manifests.append(manifest)
                    appState.compilerLog.append("  \(manifest.id): \(manifest.tools.count) tools")
                } else if let extracted = try? extractMCPManifests(from: fullPath) {
                    manifests.append(contentsOf: extracted)
                    for m in extracted {
                        appState.compilerLog.append("  \(m.id): \(m.tools.count) tools")
                    }
                }
            }
            return manifests
        } else {
            if let manifest = try? loadSingleManifest(from: path) {
                appState.compilerLog.append("  \(manifest.id): \(manifest.tools.count) tools")
                return [manifest]
            }
            if let extracted = try? extractMCPManifests(from: path) {
                for m in extracted {
                    appState.compilerLog.append("  \(m.id): \(m.tools.count) tools")
                }
                return extracted
            }
            return []
        }
    }

    private func loadSingleManifest(from path: String) throws -> ProviderManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ProviderManifest.self, from: data)
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

    // MARK: - Serialization

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
}
