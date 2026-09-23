import AppKit
import SwiftUI
import SmallChatAgents
import SmallChatTruth

/// What the stenographer walks into every chat knowing: the project wiki's
/// tombstones (TB) and unverified claims (UV).
struct StenographerView: View {
    @Environment(MessengerModel.self) private var model
    @State private var authoring = false

    var body: some View {
        let selection = model.ledger.selection
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.objections.isEmpty {
                ReceivedObjectionsList()
                    .frame(maxHeight: 240)
                Divider()
            }
            if model.ledger.entries.isEmpty {
                ContentUnavailableView {
                    Label("No ledger loaded", systemImage: "text.book.closed")
                } description: {
                    Text("Add your project wiki's truth-ledger JSONL (stenographer's `export_wiki_entries` output). The stenographer then flags tombstoned values and unverified claims in every chat.")
                } actions: {
                    Button("Add Wiki File or Folder…", action: addSource)
                }
            } else {
                List {
                    if !selection.groundTruth.isEmpty {
                        Section("Tombstones — ground truth") {
                            ForEach(selection.groundTruth, id: \.id) { TombstoneRow(tb: $0, contestedBy: []) }
                        }
                    }
                    if !selection.contested.isEmpty {
                        Section("Contested") {
                            ForEach(selection.contested, id: \.tombstone.id) { pair in
                                TombstoneRow(tb: pair.tombstone, contestedBy: pair.contestedBy)
                            }
                        }
                    }
                    let open = selection.unverified.filter { $0.contests == nil }
                    if !open.isEmpty {
                        Section("Unverified claims — flag, don't block") {
                            ForEach(open, id: \.id) { UnverifiedRow(uv: $0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stenographer")
        .sheet(isPresented: $authoring) { TombstoneSheet() }
    }

    private var header: some View {
        @Bindable var bindable = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stenographer").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Watch every chat", isOn: $bindable.settings.stenographerWatching)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Watches every conversation for tombstoned values and reliance on unverified claims. Notes are shown only to you. Ask it anything with @stenographer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Objection channel:").font(.caption)
                ObjectionChannelStatusLabel().font(.caption)
                Spacer()
                Button("Copy stenographer command") { copyToPasteboard(stenographerCommand(model)) }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                ForEach(model.settings.wikiPaths, id: \.self) { path in
                    HStack(spacing: 4) {
                        Text((path as NSString).lastPathComponent).font(.caption.monospaced())
                        Button {
                            model.settings.wikiPaths.removeAll { $0 == path }
                            model.reloadLedger()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help(path)
                }
                Button("New Tombstone…") { authoring = true }.controlSize(.small)
                Button("Add…", action: addSource).controlSize(.small)
                Button("Reload") { model.reloadLedger() }.controlSize(.small)
                Spacer()
                Text("\(model.ledger.tombstones.count) TB · \(model.ledger.openClaims.count) open UV")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !model.ledger.errors.isEmpty {
                Text("\(model.ledger.errors.count) line(s) couldn't be parsed: \(model.ledger.errors.first ?? "")")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose wiki truth-ledger JSONL files, or a folder of them"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.settings.wikiPaths.contains(url.path) {
            model.settings.wikiPaths.append(url.path)
        }
        model.reloadLedger()
    }
}

struct TombstoneRow: View {
    let tb: TruthTbEntry
    let contestedBy: [TruthUvEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(contestedBy.isEmpty ? "TB" : "TB ⚠ CONTESTED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(contestedBy.isEmpty ? Color.primary : Color.orange)
                Text(tb.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(tb.signedBy ?? tb.author).font(.caption2).foregroundStyle(.secondary)
            }
            Text(tb.claim)
            if !tb.literals.isEmpty {
                Text("Objects to: " + tb.literals.map { lit in
                    (lit.subject.map { "\($0) = " } ?? "") + lit.dead + (lit.current.map { " (now \($0))" } ?? "")
                }.joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            ForEach(contestedBy, id: \.id) { uv in
                Text("↳ disputed by \(uv.id): \(uv.assertion)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

struct UnverifiedRow: View {
    let uv: TruthUvEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("UV — UNVERIFIED").font(.caption2.weight(.bold)).foregroundStyle(Theme.stenographer)
                Text(uv.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(uv.author).font(.caption2).foregroundStyle(.secondary)
            }
            Text(uv.assertion)
            Text("Basis: \(uv.basis)").font(.caption).foregroundStyle(.secondary)
            Text("Verify by \(uv.verifyBy.kind.rawValue): \(uv.verifyBy.value)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

/// Objections stenographer pushed over the channel, newest first.
struct ReceivedObjectionsList: View {
    @Environment(MessengerModel.self) private var model

    var body: some View {
        List {
            Section("Received objections") {
                ForEach(model.objections) { objection in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            Text(objection.objectionIds.joined(separator: ", "))
                                .font(.caption2.monospaced())
                            if !objection.tbIds.isEmpty {
                                Text("↳ " + objection.tbIds.joined(separator: ", "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(objection.receivedAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(objection.content)
                            .font(.callout)
                            .lineLimit(4)
                            .textSelection(.enabled)
                        Text(routing(objection))
                            .font(.caption2)
                            .foregroundStyle(objection.routedTo.isEmpty ? Color.orange : Color.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func routing(_ objection: ReceivedObjection) -> String {
        guard !objection.routedTo.isEmpty else {
            return "No known session matched " + objection.sessionIds.joined(separator: ", ")
        }
        let handles = objection.routedTo.compactMap { model.agent($0).map { "@\($0.handle)" } }
        let relayed = objection.relayedTo.compactMap { model.agent($0).map { "@\($0.handle)" } }
        return "Posted to " + handles.joined(separator: ", ")
            + (relayed.isEmpty ? "" : " · relayed into " + relayed.joined(separator: ", "))
    }
}
