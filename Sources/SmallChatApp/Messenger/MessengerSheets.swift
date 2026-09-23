import AppKit
import SwiftUI
import SmallChatAgents

enum MessengerSheet: Identifiable, Hashable {
    case newAgent
    case newGroup(preselected: [String])
    case manageGroup(String)
    case rename(String)

    var id: String {
        switch self {
        case .newAgent: return "new-agent"
        case .newGroup(let ids): return "new-group-" + ids.joined(separator: ",")
        case .manageGroup(let id): return "manage-" + id
        case .rename(let id): return "rename-" + id
        }
    }
}

struct MessengerSheetView: View {
    let sheet: MessengerSheet
    @Binding var selection: SidebarItem?

    var body: some View {
        switch sheet {
        case .newAgent:
            NewAgentSheet(selection: $selection)
        case .newGroup(let preselected):
            GroupEditorSheet(conversationId: nil, preselected: Set(preselected), selection: $selection)
        case .manageGroup(let id):
            GroupEditorSheet(conversationId: id, preselected: [], selection: $selection)
        case .rename(let id):
            RenameAgentSheet(agentId: id)
        }
    }
}

// MARK: - Rename

struct RenameAgentSheet: View {
    @Environment(MessengerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agentId: String
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Agent").font(.headline)
            if let agent = model.agent(agentId) {
                Text("\(agent.project) · \(agent.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Text("@").foregroundStyle(.secondary)
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Letters, digits, - and _. This is the durable name you @mention; it doesn't change what Claude Code calls the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = model.agent(agentId)?.handle ?? "" }
        .onChange(of: name) { _, _ in error = nil }
    }

    private func save() {
        do {
            try model.rename(agentId: agentId, to: name)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Group editor

struct GroupEditorSheet: View {
    @Environment(MessengerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil creates a new group.
    let conversationId: String?
    let preselected: Set<String>
    @Binding var selection: SidebarItem?
    @State private var title = ""
    @State private var members: Set<String> = []
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(conversationId == nil ? "New Group Chat" : "Edit Group").font(.headline)
            TextField("Group name (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Filter agents", text: $filter)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(candidates) { agent in
                    Toggle(isOn: binding(for: agent.id)) {
                        HStack {
                            Circle().fill(Theme.activityColor(agent.activity)).frame(width: 7, height: 7)
                            Text("@\(agent.handle)").fontWeight(.medium)
                            Text(agent.project).foregroundStyle(.secondary)
                            Spacer()
                            if agent.kind != .unknown { KindChip(kind: agent.kind) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 220)
            Text("You're always in the group. Messages fan out to every agent; replies come to you privately until you share them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(members.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(conversationId == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(members.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 460)
        .onAppear {
            if let id = conversationId, let conversation = model.conversation(id) {
                title = conversation.title
                members = Set(conversation.memberIds)
            } else {
                members = preselected
            }
        }
    }

    private var candidates: [AgentSession] {
        let q = filter.lowercased()
        // Keep current members visible even if filtered out of the main list.
        let pool = model.agents + members.compactMap { id in model.agents.contains { $0.id == id } ? nil : model.agent(id) }
        return pool.filter { q.isEmpty || $0.handle.contains(q) || $0.project.lowercased().contains(q) }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { members.contains(id) },
            set: { isOn in
                if isOn { members.insert(id) } else { members.remove(id) }
            }
        )
    }

    private func save() {
        // Preserve the order agents appear in the list.
        let ordered = candidates.map(\.id).filter(members.contains)
        if let id = conversationId {
            model.setMembers(ordered, of: id)
            model.renameConversation(id, to: title)
        } else if let id = model.createGroup(title: title, memberIds: ordered) {
            selection = .conversation(id)
        }
        dismiss()
    }
}

// MARK: - New agent

struct NewAgentSheet: View {
    @Environment(MessengerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: SidebarItem?
    @State private var name = ""
    @State private var directory = ""
    @State private var prompt = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent Session").font(.headline)
            Text("Starts a new Claude Code session in a directory and opens a chat with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Name") {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("e.g. compat-guard", text: $name).textFieldStyle(.roundedBorder)
                }
            }
            LabeledContent("Directory") {
                HStack {
                    TextField("/path/to/repo", text: $directory).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseDirectory)
                }
            }
            Text("First message").font(.subheadline)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || directory.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if directory.isEmpty, let recent = model.agents.first?.cwd { directory = recent }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
            if name.isEmpty { name = Handles.slugify(url.lastPathComponent) }
        }
    }

    private func start() {
        let path = (directory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            error = "That directory doesn't exist."
            return
        }
        do {
            try model.startAgent(handle: name, cwd: path, prompt: prompt)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
