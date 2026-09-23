import SwiftUI
import SmallChatAgents

/// What the sidebar has selected.
enum SidebarItem: Hashable {
    case agent(String)
    case conversation(String)
    case stenographer
    case tool(AppSection)
}

/// The messenger window: sessions on the left, the chat on the right.
struct MessengerRootView: View {
    @Environment(MessengerModel.self) private var model
    @State private var selection: SidebarItem?
    @State private var sheet: MessengerSheet?

    var body: some View {
        NavigationSplitView {
            MessengerSidebar(selection: $selection, sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    sheet = .newAgent
                } label: {
                    Label("New Agent Session", systemImage: "plus.bubble")
                }
                .help("Start a new Claude Code session")
                Button {
                    sheet = .newGroup(preselected: [])
                } label: {
                    Label("New Group Chat", systemImage: "person.3")
                }
                .help("Create a group chat with one or more agents")
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .sheet(item: $sheet) { sheet in
            MessengerSheetView(sheet: sheet, selection: $selection)
        }
        .onChange(of: selection) { _, newValue in
            if case .agent(let id) = newValue { model.openDirect(agentId: id) }
            if case .conversation(let id) = newValue { model.selectedConversationId = id }
        }
        .onChange(of: model.selectedConversationId) { _, id in
            // Keep the sidebar in step when the model opens a chat itself
            // (new session, inbound reply from an agent with no open chat).
            guard let id, let conversation = model.conversation(id) else { return }
            let item: SidebarItem = conversation.kind == .direct && conversation.memberIds.count == 1
                ? .agent(conversation.memberIds[0]) : .conversation(id)
            if selection != item { selection = item }
        }
        .task {
            await model.refresh()
            await model.refreshLiveNames()
        }
        .task {
            // Live status is cheap (a few small JSON files); transcripts are not.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                ticks += 1
                if ticks % 20 == 0 {
                    await model.refresh()
                } else {
                    await model.refreshLive()
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .agent(let id):
            if let conversation = model.directConversation(with: id) {
                ChatView(conversationId: conversation.id, sheet: $sheet)
                    .id(conversation.id)
            } else {
                ProgressView()
            }
        case .conversation(let id):
            if model.conversation(id) != nil {
                ChatView(conversationId: id, sheet: $sheet)
                    .id(id)
            } else {
                EmptyChatView()
            }
        case .stenographer:
            StenographerView()
        case .tool(let section):
            ToolkitDetailView(section: section)
        case nil:
            EmptyChatView()
        }
    }
}

struct EmptyChatView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Pick an agent", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Choose a Claude Code session on the left to chat with it, or start a group chat. Type @name to message or tag an agent directly.")
        }
    }
}

/// The original tool-compiler panels, reachable from the sidebar's Toolkit section.
struct ToolkitDetailView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .compiler: CompilerView()
        case .server: ServerView()
        case .manifest: ManifestEditorView()
        case .inspector: InspectorView()
        case .resolver: ResolverView()
        case .discovery: DiscoveryView()
        case .refinement: RefinementView()
        case .apps: AppsView()
        case .doctor: DoctorView()
        }
    }
}
