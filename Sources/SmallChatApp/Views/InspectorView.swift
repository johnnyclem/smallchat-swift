import SwiftUI
import UniformTypeIdentifiers
import SmallChat

struct InspectorView: View {
    @Environment(AppState.self) private var appState
    @State private var showSelectors = true
    @State private var showProviders = true
    @State private var showCollisions = true

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Artifact Inspector")
                    .font(.largeTitle.bold())

                Text("Examine a compiled .toolkit.json artifact.")
                    .foregroundStyle(.secondary)

                Divider()

                // File Picker
                HStack {
                    TextField("Artifact file path", text: $state.inspectorFilePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { chooseArtifact() }
                    Button("Load") { loadArtifact() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.inspectorFilePath.isEmpty)
                }

                // Stats Summary
                if !state.inspectorVersion.isEmpty {
                    GroupBox("Summary") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Text("Version:").fontWeight(.medium)
                                Text(state.inspectorVersion)
                            }
                            GridRow {
                                Text("Compiled:").fontWeight(.medium)
                                Text(state.inspectorTimestamp)
                            }
                            GridRow {
                                Text("Tools:").fontWeight(.medium)
                                Text("\(state.inspectorToolCount)")
                            }
                            GridRow {
                                Text("Unique Selectors:").fontWeight(.medium)
                                Text("\(state.inspectorSelectorCount)")
                            }
                            GridRow {
                                Text("Providers:").fontWeight(.medium)
                                Text("\(state.inspectorProviderCount)")
                            }
                            GridRow {
                                Text("Merged:").fontWeight(.medium)
                                Text("\(state.inspectorMergedCount)")
                            }
                            GridRow {
                                Text("Collisions:").fontWeight(.medium)
                                Text("\(state.inspectorCollisionCount)")
                                    .foregroundStyle(state.inspectorCollisionCount > 0 ? .orange : .primary)
                            }
                            if !state.inspectorEmbeddingModel.isEmpty {
                                GridRow {
                                    Text("Embedding:").fontWeight(.medium)
                                    Text("\(state.inspectorEmbeddingModel) (\(state.inspectorEmbeddingDimensions)-dim)")
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                // Selectors
                if !state.inspectorSelectors.isEmpty {
                    DisclosureGroup("Selectors (\(state.inspectorSelectors.count))", isExpanded: $showSelectors) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(state.inspectorSelectors, id: \.canonical) { sel in
                                HStack {
                                    Text(sel.canonical)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("arity: \(sel.arity)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .background(.fill.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Providers
                if !state.inspectorProviders.isEmpty {
                    DisclosureGroup("Providers (\(state.inspectorProviders.count))", isExpanded: $showProviders) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.inspectorProviders, id: \.id) { provider in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.id)
                                        .fontWeight(.semibold)
                                    ForEach(provider.tools, id: \.self) { tool in
                                        Text("  - \(tool)")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .background(.fill.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Collisions
                if !state.inspectorCollisions.isEmpty {
                    DisclosureGroup("Collisions (\(state.inspectorCollisions.count))", isExpanded: $showCollisions) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.inspectorCollisions, id: \.selectorA) { collision in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text("\(collision.selectorA) <-> \(collision.selectorB)")
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("\(String(format: "%.1f", collision.similarity * 100))%")
                                            .monospacedDigit()
                                            .foregroundStyle(.orange)
                                    }
                                    Text(collision.hint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .background(.fill.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func chooseArtifact() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.title = "Open compiled artifact"
        if panel.runModal() == .OK, let url = panel.url {
            appState.inspectorFilePath = url.path
        }
        #endif
    }

    private func loadArtifact() {
        do {
            // Artifact format 1.0, validated (schema, consistency, content hash).
            let artifact = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: appState.inspectorFilePath))

            appState.inspectorVersion = "format \(ARTIFACT_FORMAT_VERSION)"
            appState.inspectorTimestamp = "content hash \(artifact.contentHash.prefix(12))…"

            appState.inspectorToolCount = artifact.tools.count
            appState.inspectorSelectorCount = artifact.selectors.count
            appState.inspectorProviderCount = artifact.providers.count
            appState.inspectorCollisionCount = artifact.collisions.count
            appState.inspectorMergedCount = 0

            appState.inspectorEmbeddingModel = artifact.embedder.summary
            appState.inspectorEmbeddingDimensions = artifact.embedder.dims

            appState.inspectorSelectors = artifact.selectors.keys.sorted().map { canonical in
                (canonical: canonical, arity: max(0, canonical.split(separator: ":").count - 1))
            }

            appState.inspectorProviders = artifact.providers.keys.sorted().map { providerId in
                let tools = artifact.tools.values.filter { $0.providerId == providerId }.map(\.name).sorted()
                return (id: providerId, tools: tools)
            }

            appState.inspectorCollisions = artifact.collisions.map { c in
                (selectorA: c.selectorA, selectorB: c.selectorB, similarity: c.similarity, hint: c.hint)
            }
        } catch {
            appState.inspectorVersion = "Error: \(error.localizedDescription)"
        }
    }
}
