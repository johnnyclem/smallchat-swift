import AppKit
import SwiftUI
import SmallChatAgents

struct MessengerSidebar: View {
    @Environment(MessengerModel.self) private var model
    @Binding var selection: SidebarItem?
    @Binding var sheet: MessengerSheet?
    @State private var filter = ""
    @State private var showArchived = false
    @State private var showToolkit = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Button {
                    sheet = .newAgent
                } label: {
                    Label("New Agent Session", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                Button {
                    sheet = .newGroup(preselected: [])
                } label: {
                    Label("New Group Chat", systemImage: "person.3.fill")
                }
                .buttonStyle(.plain)
                Label {
                    HStack {
                        Text("Stenographer")
                        Spacer()
                        Text("\(model.ledger.tombstones.count) TB · \(model.ledger.openClaims.count) UV")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.book.closed")
                }
                .tag(SidebarItem.stenographer)
            }

            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups) { group in
                        GroupRow(conversation: group)
                            .tag(SidebarItem.conversation(group.id))
                            .contextMenu {
                                Button("Edit Group…") { sheet = .manageGroup(group.id) }
                                Divider()
                                Button("Delete Group", role: .destructive) {
                                    if selection == .conversation(group.id) { selection = nil }
                                    model.deleteConversation(group.id)
                                }
                            }
                    }
                }
            }

            Section {
                ForEach(filteredAgents) { agent in
                    SessionCard(agent: agent)
                        .tag(SidebarItem.agent(agent.id))
                        .contextMenu { agentMenu(agent) }
                }
                if filteredAgents.isEmpty {
                    Text(filter.isEmpty ? "No Claude Code sessions found." : "No matches.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
                    let live = model.agents.filter(\.isLive).count
                    if live > 0 {
                        Text("\(live) LIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.2)))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            if !model.archivedAgents.isEmpty {
                Section {
                    DisclosureGroup("Archived (\(model.archivedAgents.count))", isExpanded: $showArchived) {
                        ForEach(model.archivedAgents) { agent in
                            SessionCard(agent: agent)
                                .opacity(0.6)
                                .tag(SidebarItem.agent(agent.id))
                                .contextMenu { agentMenu(agent) }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Toolkit", isExpanded: $showToolkit) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(SidebarItem.tool(section))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter agents")
        .navigationTitle("smallchat")
    }

    private var filteredAgents: [AgentSession] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.agents }
        return model.agents.filter {
            $0.handle.contains(q) || $0.project.lowercased().contains(q) || ($0.title?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder
    private func agentMenu(_ agent: AgentSession) -> some View {
        Button("Open Chat") { selection = .agent(agent.id) }
        Button("Rename…") { sheet = .rename(agent.id) }
        Button("New Group with @\(agent.handle)…") { sheet = .newGroup(preselected: [agent.id]) }
        Divider()
        if agent.archived {
            Button("Unarchive") { model.setArchived(agentId: agent.id, false) }
        } else {
            Button("Archive") {
                if selection == .agent(agent.id) { selection = nil }
                model.setArchived(agentId: agent.id, true)
            }
        }
        Divider()
        Button("Copy Session ID") { copyToPasteboard(agent.id) }
        Button("Copy Resume Command") { copyToPasteboard("cd \(shellQuote(agent.cwd)) && claude --resume \(agent.id)") }
        if let path = agent.transcriptPath {
            Button("Show Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}

struct GroupRow: View {
    @Environment(MessengerModel.self) private var model
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18))
                Image(systemName: "person.3.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(conversation.memberIds.compactMap { model.agent($0).map { "@\($0.handle)" } }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let pending = conversation.messages.filter(\.awaitingShareDecision).count
            if pending > 0 {
                Text("\(pending)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundStyle(.white)
                    .help("Private replies waiting for you to share or keep")
            }
        }
        .padding(.vertical, 2)
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
