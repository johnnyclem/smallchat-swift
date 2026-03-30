import SwiftUI
import UniformTypeIdentifiers
import SmallChat

struct ResolverView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Intent Resolver")
                    .font(.largeTitle.bold())

                Text("Test dispatch resolution against a compiled artifact. Enter a natural language intent and see which tools match.")
                    .foregroundStyle(.secondary)

                Divider()

                // Artifact Path
                GroupBox("Artifact") {
                    HStack {
                        TextField("Compiled artifact path", text: $state.resolverArtifactPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { chooseArtifact() }
                    }
                    .padding(4)
                }

                // Intent Input
                GroupBox("Intent") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Enter natural language intent (e.g. \"search for files\")", text: $state.resolverIntent)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 16) {
                            HStack {
                                Text("Top-K:")
                                TextField("5", value: $state.resolverTopK, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                            }
                            HStack {
                                Text("Threshold:")
                                TextField("0.5", value: $state.resolverThreshold, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                            }
                            Spacer()
                        }
                    }
                    .padding(4)
                }

                // Resolve Button
                HStack {
                    Button(action: { Task { await resolve() } }) {
                        Label("Resolve", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.resolverArtifactPath.isEmpty || state.resolverIntent.isEmpty || state.isResolving)

                    if state.isResolving {
                        ProgressView()
                            .controlSize(.small)
                        Text("Resolving...")
                            .foregroundStyle(.secondary)
                    }
                }

                // Results
                if !state.resolverMatches.isEmpty {
                    GroupBox("Results") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(state.resolverMatches.enumerated()), id: \.element.id) { index, match in
                                HStack {
                                    Text("\(index + 1).")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Text(match.selector)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(index == 0 ? .bold : .regular)
                                    Spacer()
                                    Text(String(format: "%.1f%%", match.confidence))
                                        .monospacedDigit()
                                        .foregroundStyle(confidenceColor(match.confidence))
                                    Text("(\(match.provider))")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .padding(.vertical, 2)
                            }

                            Divider()

                            if let best = state.resolverMatches.first {
                                if best.confidence > 90 {
                                    Label("Unambiguous: \(best.selector) (\(String(format: "%.1f", best.confidence))%)",
                                          systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("Ambiguous: top match is \(best.selector). Disambiguation may be needed.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                // Log
                if !state.resolverLog.isEmpty {
                    LogView(state.resolverLog, title: "Resolver Output")
                        .frame(minHeight: 100, maxHeight: 200)
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
            appState.resolverArtifactPath = url.path
        }
        #endif
    }

    @MainActor
    private func resolve() async {
        appState.isResolving = true
        appState.resolverMatches = []
        appState.resolverLog = []
        appState.resolverLog.append("Loading artifact from \(appState.resolverArtifactPath)...")

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: appState.resolverArtifactPath))
            guard let artifact = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let selectorsDict = artifact["selectors"] as? [String: Any],
                  let dispatchTablesDict = artifact["dispatchTables"] as? [String: Any] else {
                appState.resolverLog.append("ERROR: Failed to parse artifact")
                appState.isResolving = false
                return
            }

            let embedder = LocalEmbedder()
            let vectorIndex = MemoryVectorIndex()
            let selectorTable = SelectorTable(index: vectorIndex, embedder: embedder)

            // Load selectors
            for (_, selValue) in selectorsDict {
                guard let sel = selValue as? [String: Any],
                      let canonical = sel["canonical"] as? String,
                      let vectorArr = sel["vector"] as? [NSNumber] else { continue }
                let vector = vectorArr.map { Float(truncating: $0) }
                _ = try await selectorTable.intern(embedding: vector, canonical: canonical)
            }

            // Resolve intent
            let selector = try await selectorTable.resolve(appState.resolverIntent)
            let matches = try await vectorIndex.search(
                query: selector.vector,
                topK: appState.resolverTopK,
                threshold: appState.resolverThreshold
            )

            appState.resolverLog.append("Intent: \"\(appState.resolverIntent)\"")
            appState.resolverLog.append("Resolved selector: \(selector.canonical)")

            appState.resolverMatches = matches.map { match in
                let confidence = Double(1 - match.distance) * 100
                var provider = "unknown"
                for (providerId, table) in dispatchTablesDict {
                    if let methods = table as? [String: Any], methods[match.id] != nil {
                        provider = providerId
                        break
                    }
                }
                return ResolvedMatch(selector: match.id, confidence: confidence, provider: provider)
            }

            appState.resolverLog.append("Found \(matches.count) match(es)")

        } catch {
            appState.resolverLog.append("ERROR: \(error.localizedDescription)")
        }

        appState.isResolving = false
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence > 90 { return .green }
        if confidence > 70 { return .orange }
        return .red
    }
}
