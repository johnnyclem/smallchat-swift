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
            ObjectionChannelSettings()
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

/// Settings for the loopback bridge stenographer's `--objection-channel` posts to.
struct ObjectionChannelSettings: View {
    @Environment(MessengerModel.self) private var model
    @State private var port = ""
    @State private var restPort = ""
    @State private var revealSecret = false

    var body: some View {
        @Bindable var bindable = model
        Section {
            Toggle("Receive objections from stenographer", isOn: $bindable.settings.objectionChannelEnabled)
                .onChange(of: model.settings.objectionChannelEnabled) { _, _ in restart() }
            LabeledContent("Status") { ObjectionChannelStatusLabel() }
            HStack {
                TextField("Port", text: $port)
                    .frame(width: 90)
                    .onSubmit(applyPort)
                Button("Apply", action: applyPort)
            }
            LabeledContent("Secret") {
                HStack {
                    Text(revealSecret ? model.settings.objectionChannelSecret : String(repeating: "•", count: 16))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(revealSecret ? "Hide" : "Show") { revealSecret.toggle() }
                    Button("Copy") { copyToPasteboard(model.settings.objectionChannelSecret) }
                }
            }
            Toggle("Relay objections into the agent's live session", isOn: $bindable.settings.relayObjections)
            HStack {
                TextField("Stenographer REST port", text: $restPort)
                    .frame(width: 90)
                    .onSubmit(applyRestPort)
                Button("Apply", action: applyRestPort)
                Text("where you approve agent-drafted tombstones").font(.caption).foregroundStyle(.secondary)
            }
            Button("Copy stenographer command") { copyToPasteboard(stenographerCommand(model)) }
        } header: {
            Text("Objection channel")
        } footer: {
            Text("Stenographer pushes each real-time objection here as it's raised (`--objections deliver --objection-channel`). It lands in the offending agent's chats and, if relaying is on, interrupts that live session so it can correct course. Tombstones agents draft arrive here too and wait for you to notarize them; with `--require-notary`, agents can't assert tombstones any other way. Loopback only.")
        }
        .onAppear {
            port = String(model.settings.objectionChannelPort)
            restPort = String(model.settings.stenographerRestPort)
        }
    }

    private func applyRestPort() {
        guard let value = Int(restPort), (1...65535).contains(value) else {
            restPort = String(model.settings.stenographerRestPort)
            return
        }
        model.settings.stenographerRestPort = value
    }

    private func applyPort() {
        guard let value = Int(port), (1...65535).contains(value) else {
            port = String(model.settings.objectionChannelPort)
            return
        }
        model.settings.objectionChannelPort = value
        restart()
    }

    private func restart() {
        Task { await model.startObjectionChannel() }
    }
}

struct ObjectionChannelStatusLabel: View {
    @Environment(MessengerModel.self) private var model

    var body: some View {
        switch model.objectionChannelStatus {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .listening(let port):
            Label("Listening on 127.0.0.1:\(port)", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .failed(let reason):
            Label("Couldn't start: \(reason)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

/// Shell command that starts stenographer delivering objections to this app.
@MainActor
/// The same secret authenticates stenographer to the bridge and the messenger
/// to stenographer's notary routes. Agents never get it.
func stenographerCommand(_ model: MessengerModel) -> String {
    let secret = model.settings.objectionChannelSecret
    return "SMALLCHAT_CHANNEL_SECRET=\(secret) STENOGRAPHER_NOTARY_SECRET=\(secret) stenographer start <log-or-dir>"
        + " --objections deliver --objection-channel \(model.objectionChannelURL)"
        + " --rest-port \(model.settings.stenographerRestPort) --require-notary"
}
