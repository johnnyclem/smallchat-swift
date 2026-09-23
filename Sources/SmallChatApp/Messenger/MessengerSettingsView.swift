import SwiftUI
import SmallChatAgents

struct MessengerSettingsView: View {
    @Environment(MessengerModel.self) private var model
    @State private var claudePath = ""

    var body: some View {
        @Bindable var bindable = model
        Form {
            Section("Claude Code") {
                TextField("claude executable", text: $claudePath, prompt: Text("auto-detect"))
                    .onSubmit(applyClaudePath)
                LabeledContent("Using") {
                    Text(resolvedPath ?? "not found — install Claude Code or set the path above")
                        .font(.caption.monospaced())
                        .foregroundStyle(resolvedPath == nil ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
                Button("Apply", action: applyClaudePath)
            }
            Section {
                TextField("Switchboard model", text: $bindable.settings.switchboardModel)
                TextField("Stenographer model", text: $bindable.settings.stenographerModel)
            } header: {
                Text("Models")
            } footer: {
                Text("The switchboard only relays messages between you and live sessions via Claude Code's inter-agent messaging, so a small model is plenty. Changes apply on next launch.")
            }
            Section("Sessions") {
                Picker("Show stopped sessions from the last", selection: $bindable.settings.recentDays) {
                    Text("7 days").tag(Int?.some(7))
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                    Text("All time").tag(Int?.none)
                }
            }
            Section("Stenographer") {
                Toggle("Watch every chat", isOn: $bindable.settings.stenographerWatching)
                ForEach(model.settings.wikiPaths, id: \.self) { Text($0).font(.caption.monospaced()) }
                if model.settings.wikiPaths.isEmpty {
                    Text("No wiki ledger configured — add one from the Stenographer page.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear { claudePath = model.settings.claudePath ?? "" }
    }

    private var resolvedPath: String? {
        ClaudeCommand.locateExecutable(preferred: model.settings.claudePath)
    }

    private func applyClaudePath() {
        let trimmed = claudePath.trimmingCharacters(in: .whitespaces)
        model.settings.claudePath = trimmed.isEmpty ? nil : trimmed
        model.setTransport(AgentTransports.make(settings: model.settings))
    }
}
