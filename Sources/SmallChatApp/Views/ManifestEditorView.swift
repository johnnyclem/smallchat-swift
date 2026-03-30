import SwiftUI
import UniformTypeIdentifiers
import SmallChat

struct ManifestEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var newDepKey: String = ""
    @State private var newDepValue: String = ""
    @State private var newManifestDir: String = ""
    @State private var statusMessage: String = ""

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Text("Manifest Editor")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("Load...") { loadManifest() }
                    Button("Save") { saveManifest() }
                        .buttonStyle(.borderedProminent)
                    Button("Save As...") { saveManifestAs() }
                }

                Text("Create and edit smallchat.json project manifests.")
                    .foregroundStyle(.secondary)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                }

                Divider()

                // Project Info
                GroupBox("Project") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Name:")
                                .frame(width: 100, alignment: .leading)
                            TextField("my-project", text: $state.manifestName)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Version:")
                                .frame(width: 100, alignment: .leading)
                            TextField("0.1.0", text: $state.manifestVersion)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                        HStack(alignment: .top) {
                            Text("Description:")
                                .frame(width: 100, alignment: .leading)
                            TextField("A brief description of the project", text: $state.manifestDescription, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                        }
                    }
                    .padding(4)
                }

                // Dependencies
                GroupBox("Dependencies") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(state.manifestDependencies.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .fontWeight(.medium)
                                Text(state.manifestDependencies[key] ?? "")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(role: .destructive) {
                                    state.manifestDependencies.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            TextField("Package name", text: $newDepKey)
                                .textFieldStyle(.roundedBorder)
                            TextField("Version or path", text: $newDepValue)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                guard !newDepKey.isEmpty else { return }
                                state.manifestDependencies[newDepKey] = newDepValue
                                newDepKey = ""
                                newDepValue = ""
                            }
                            .disabled(newDepKey.isEmpty)
                        }
                    }
                    .padding(4)
                }

                // Manifest Directories
                GroupBox("Manifest Directories") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(state.manifestDirectories.enumerated()), id: \.offset) { index, dir in
                            HStack {
                                Text(dir)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    state.manifestDirectories.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            TextField("./manifests", text: $newManifestDir)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                guard !newManifestDir.isEmpty else { return }
                                state.manifestDirectories.append(newManifestDir)
                                newManifestDir = ""
                            }
                            .disabled(newManifestDir.isEmpty)
                            Button("Browse...") { browseManifestDir() }
                        }
                    }
                    .padding(4)
                }

                // Compiler Config
                GroupBox("Compiler Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Embedder:")
                                .frame(width: 180, alignment: .leading)
                            Picker("", selection: $state.manifestEmbedder) {
                                Text("Local (FNV-1a hash)").tag("local")
                                Text("ONNX").tag("onnx")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }

                        HStack {
                            Text("Deduplication Threshold:")
                                .frame(width: 180, alignment: .leading)
                            Slider(value: $state.manifestDeduplicationThreshold, in: 0.5...1.0, step: 0.01)
                            Text(String(format: "%.2f", state.manifestDeduplicationThreshold))
                                .monospacedDigit()
                                .frame(width: 40)
                        }

                        HStack {
                            Text("Collision Threshold:")
                                .frame(width: 180, alignment: .leading)
                            Slider(value: $state.manifestCollisionThreshold, in: 0.5...1.0, step: 0.01)
                            Text(String(format: "%.2f", state.manifestCollisionThreshold))
                                .monospacedDigit()
                                .frame(width: 40)
                        }

                        Toggle("Generate Semantic Overloads", isOn: $state.manifestGenerateOverloads)
                    }
                    .padding(4)
                }

                // Output Config
                GroupBox("Output Configuration") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Output Path:")
                                .frame(width: 100, alignment: .leading)
                            TextField("tools.toolkit.json", text: $state.manifestOutputPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Format:")
                                .frame(width: 100, alignment: .leading)
                            Picker("", selection: $state.manifestOutputFormat) {
                                Text("JSON").tag("json")
                                Text("SQLite").tag("sqlite")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                        if state.manifestOutputFormat == "sqlite" {
                            HStack {
                                Text("DB Path:")
                                    .frame(width: 100, alignment: .leading)
                                TextField("smallchat.db", text: $state.manifestDbPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func loadManifest() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.title = "Open smallchat.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(SmallChatManifest.self, from: data)
            appState.manifestPath = url.path
            appState.manifestName = manifest.name
            appState.manifestVersion = manifest.version
            appState.manifestDescription = manifest.description ?? ""
            appState.manifestDependencies = manifest.dependencies ?? [:]
            appState.manifestDirectories = manifest.manifests ?? []
            appState.manifestEmbedder = manifest.compiler?.embedder ?? "local"
            appState.manifestDeduplicationThreshold = manifest.compiler?.deduplicationThreshold ?? 0.95
            appState.manifestCollisionThreshold = manifest.compiler?.collisionThreshold ?? 0.89
            appState.manifestGenerateOverloads = manifest.compiler?.generateSemanticOverloads ?? false
            appState.manifestOutputPath = manifest.output?.path ?? "tools.toolkit.json"
            appState.manifestOutputFormat = manifest.output?.format?.rawValue ?? "json"
            appState.manifestDbPath = manifest.output?.dbPath ?? ""
            statusMessage = "Loaded: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error loading manifest: \(error.localizedDescription)"
        }
        #endif
    }

    private func saveManifest() {
        if appState.manifestPath.isEmpty {
            saveManifestAs()
            return
        }
        writeManifest(to: URL(fileURLWithPath: appState.manifestPath))
    }

    private func saveManifestAs() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "smallchat.json"
        panel.title = "Save manifest"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.manifestPath = url.path
        writeManifest(to: url)
        #endif
    }

    private func writeManifest(to url: URL) {
        let outputFormat: ManifestOutputConfig.OutputFormat? =
            appState.manifestOutputFormat == "sqlite" ? .sqlite : .json

        let manifest = SmallChatManifest(
            name: appState.manifestName,
            version: appState.manifestVersion,
            description: appState.manifestDescription.isEmpty ? nil : appState.manifestDescription,
            dependencies: appState.manifestDependencies.isEmpty ? nil : appState.manifestDependencies,
            manifests: appState.manifestDirectories.isEmpty ? nil : appState.manifestDirectories,
            compiler: ManifestCompilerConfig(
                embedder: appState.manifestEmbedder,
                deduplicationThreshold: appState.manifestDeduplicationThreshold,
                collisionThreshold: appState.manifestCollisionThreshold,
                generateSemanticOverloads: appState.manifestGenerateOverloads
            ),
            output: ManifestOutputConfig(
                path: appState.manifestOutputPath,
                format: outputFormat,
                dbPath: appState.manifestDbPath.isEmpty ? nil : appState.manifestDbPath
            )
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url)
            statusMessage = "Saved: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error saving: \(error.localizedDescription)"
        }
    }

    private func browseManifestDir() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.title = "Select manifest directory"
        if panel.runModal() == .OK, let url = panel.url {
            appState.manifestDirectories.append(url.path)
        }
        #endif
    }
}
