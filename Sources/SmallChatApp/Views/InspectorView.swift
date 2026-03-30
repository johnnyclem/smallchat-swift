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
            let data = try Data(contentsOf: URL(fileURLWithPath: appState.inspectorFilePath))
            guard let artifact = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            appState.inspectorVersion = artifact["version"] as? String ?? "unknown"
            appState.inspectorTimestamp = artifact["timestamp"] as? String ?? "unknown"

            if let stats = artifact["stats"] as? [String: Any] {
                appState.inspectorToolCount = stats["toolCount"] as? Int ?? 0
                appState.inspectorSelectorCount = stats["uniqueSelectorCount"] as? Int ?? 0
                appState.inspectorProviderCount = stats["providerCount"] as? Int ?? 0
                appState.inspectorCollisionCount = stats["collisionCount"] as? Int ?? 0
                appState.inspectorMergedCount = stats["mergedCount"] as? Int ?? 0
            }

            if let emb = artifact["embedding"] as? [String: Any] {
                appState.inspectorEmbeddingModel = emb["model"] as? String ?? ""
                appState.inspectorEmbeddingDimensions = emb["dimensions"] as? Int ?? 0
            }

            // Selectors
            if let sels = artifact["selectors"] as? [String: Any] {
                appState.inspectorSelectors = sels.compactMap { _, value in
                    guard let s = value as? [String: Any],
                          let canonical = s["canonical"] as? String,
                          let arity = s["arity"] as? Int else { return nil }
                    return (canonical: canonical, arity: arity)
                }.sorted(by: { $0.canonical < $1.canonical })
            }

            // Providers
            if let tables = artifact["dispatchTables"] as? [String: Any] {
                appState.inspectorProviders = tables.compactMap { providerId, value in
                    guard let methods = value as? [String: Any] else { return nil }
                    let tools = methods.compactMap { _, method -> String? in
                        (method as? [String: Any])?["toolName"] as? String
                    }.sorted()
                    return (id: providerId, tools: tools)
                }.sorted(by: { $0.id < $1.id })
            }

            // Collisions
            if let cols = artifact["collisions"] as? [[String: Any]] {
                appState.inspectorCollisions = cols.compactMap { c in
                    guard let sA = c["selectorA"] as? String,
                          let sB = c["selectorB"] as? String,
                          let sim = c["similarity"] as? Double,
                          let hint = c["hint"] as? String else { return nil }
                    return (selectorA: sA, selectorB: sB, similarity: sim, hint: hint)
                }
            }
        } catch {
            appState.inspectorVersion = "Error: \(error.localizedDescription)"
        }
    }
}
