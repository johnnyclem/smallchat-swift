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
            // Artifact format 1.0, resolved with the embedder it records.
            let artifact = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: appState.resolverArtifactPath))
            let toolkit = try await MCPToolkit.make(artifact: artifact)
            let resolution = try await toolkit.runtime.resolve(appState.resolverIntent)

            appState.resolverLog.append("Intent: \"\(appState.resolverIntent)\"")
            appState.resolverLog.append("Outcome: \(resolution.outcome.rawValue) (tier \(resolution.tier.rawValue), decision \(resolution.proof.decision.rawValue))")
            if let chosen = resolution.chosen {
                appState.resolverLog.append("Chosen: \(chosen)")
            }
            if let reason = resolution.reason {
                appState.resolverLog.append("Reason: \(reason)")
            }
            appState.resolverLog.append("Proof: \(resolution.proof.proofDigest) (nothing was executed)")

            appState.resolverMatches = resolution.candidates.map { candidate in
                ResolvedMatch(
                    selector: candidate.selector,
                    confidence: candidate.score * 100,
                    provider: artifact.tools[candidate.toolId]?.providerId ?? "unknown"
                )
            }

            appState.resolverLog.append("Found \(resolution.candidates.count) candidate(s)")

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
