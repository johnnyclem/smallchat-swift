import SwiftUI
import SmallChatAgents
import SmallChatTruth

struct ChatView: View {
    @Environment(MessengerModel.self) private var model
    let conversationId: String
    @Binding var sheet: MessengerSheet?

    var body: some View {
        if let conversation = model.conversation(conversationId) {
            VStack(spacing: 0) {
                ChatHeader(conversation: conversation, sheet: $sheet)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if conversation.messages.isEmpty {
                                ConversationIntro(conversation: conversation)
                            }
                            ForEach(conversation.messages) { message in
                                MessageRow(message: message, conversation: conversation)
                                    .id(message.id)
                            }
                            WaitingIndicator(conversationId: conversationId)
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: conversation.messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                Divider()
                ComposerView(conversation: conversation)
            }
        } else {
            EmptyChatView()
        }
    }
}

// MARK: - Header

struct ChatHeader: View {
    @Environment(MessengerModel.self) private var model
    let conversation: Conversation
    @Binding var sheet: MessengerSheet?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(conversation.kind == .group ? conversation.title : "@\(conversation.title)")
                        .font(.title3.weight(.semibold))
                    if let agent = soleAgent {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.activityColor(agent.activity)).frame(width: 7, height: 7)
                            Text(agent.activity.rawValue)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if agent.kind != .unknown { KindChip(kind: agent.kind) }
                    }
                }
                if let agent = soleAgent {
                    Text(agent.cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(deliveryExplanation(for: agent))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let snapshot = model.liveActivity[agent.id] {
                        ActivityFeed(snapshot: snapshot, history: 3)
                            .padding(.top, 2)
                    }
                } else if conversation.kind == .group {
                    HStack(spacing: 6) {
                        ForEach(conversation.memberIds, id: \.self) { id in
                            if let agent = model.agent(id) { MemberChip(agent: agent) }
                        }
                    }
                }
            }
            Spacer()
            if let agent = soleAgent {
                Button("Rename…") { sheet = .rename(agent.id) }
                Button("Add to Group…") { sheet = .newGroup(preselected: [agent.id]) }
            } else if conversation.kind == .group {
                Button("Edit Group…") { sheet = .manageGroup(conversation.id) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var soleAgent: AgentSession? {
        guard conversation.kind == .direct, let id = conversation.memberIds.first else { return nil }
        return model.agent(id)
    }

    private func deliveryExplanation(for agent: AgentSession) -> String {
        if agent.isLive, agent.claudeName != nil {
            return "Live — messages arrive via Claude Code inter-agent messaging (between tool calls, or a new turn when idle)."
        }
        if agent.isLive {
            return "Live, but not yet addressable by name — messages resume it headlessly."
        }
        return "Not running — each message resumes the session headlessly for one turn."
    }
}

struct MemberChip: View {
    let agent: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.activityColor(agent.activity)).frame(width: 6, height: 6)
            Text("@\(agent.handle)")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.color(for: agent.handle).opacity(0.15)))
    }
}

struct ConversationIntro: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.kind == .group ? "Group chat" : "Direct chat")
                .font(.headline)
            Text(conversation.kind == .group
                 ? "Everything you send goes to every agent here unless you @mention specific ones. Replies come to you privately; share one to interrupt the rest of the group with it."
                 : "Messages go straight to this session. @mention another agent to loop it in, or @stenographer to ask about the record.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Messages

struct MessageRow: View {
    @Environment(MessengerModel.self) private var model
    let message: ChatMessage
    let conversation: Conversation
    @State private var tombstoning = false

    var body: some View {
        content
            .contextMenu {
                Button("Copy Text") { copyToPasteboard(message.text) }
                if message.author != .system {
                    Button("Tombstone a Value…") { tombstoning = true }
                }
            }
            .sheet(isPresented: $tombstoning) {
                TombstoneSheet(prefill: TombstoneDraft(
                    evidence: [TruthEvidence(kind: .message, ref: message.id, detail: String(message.text.prefix(200)))]
                ))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.author {
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
                .textSelection(.enabled)
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    MessageText(text: message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.85)))
                        .foregroundStyle(.white)
                    Text(userFooter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .agent(let id):
            agentRow(agent: model.agent(id))
        case .stenographer:
            StenographerNoteRow(message: message)
        }
    }

    private var isFailure: Bool {
        if case .failed = message.delivery { return true }
        return false
    }

    private var userFooter: String {
        let names = message.recipients.compactMap { model.agent($0).map { "@\($0.handle)" } }
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        switch message.delivery {
        case .pending: return "Sending to \(names.joined(separator: ", "))… · \(time)"
        case .held(let why): return "Held by recipient: \(why) · \(time)"
        case .failed: return "Not delivered · \(time)"
        case .delivered: return names.isEmpty ? time : "To \(names.joined(separator: ", ")) · \(time)"
        }
    }

    @ViewBuilder
    private func agentRow(agent: AgentSession?) -> some View {
        let handle = agent?.handle ?? "unknown"
        HStack(alignment: .top, spacing: 10) {
            Avatar(label: handle, color: Theme.color(for: handle))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("@\(handle)").font(.caption.weight(.semibold))
                    Text(message.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    if conversation.kind == .group {
                        visibilityBadge
                    }
                }
                MessageText(text: message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
                    .overlay {
                        if message.visibility == .privateToUser {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(.secondary)
                        }
                    }
                if message.awaitingShareDecision {
                    HStack(spacing: 8) {
                        Button {
                            model.share(messageId: message.id, in: conversation.id)
                        } label: {
                            Label("Share with group", systemImage: "arrowshape.turn.up.right.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .help("Send this to every other agent in the group as an inter-agent interrupt")
                        Button("Keep private") {
                            model.keepPrivate(messageId: message.id, in: conversation.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 60)
        }
    }

    @ViewBuilder
    private var visibilityBadge: some View {
        if message.visibility == .group {
            Label("Shared with group", systemImage: "person.3")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Label("Only you", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Message text with @mentions highlighted and markdown rendered inline.
struct MessageText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let plain = String(result.characters)
        for mention in MentionParser.parse(plain).mentions {
            guard let range = Range(mention.range, in: plain) else { continue }
            // `plain` is built from `result.characters`, so character offsets line up.
            let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let lower = result.characters.index(result.characters.startIndex, offsetBy: start)
            let upper = result.characters.index(lower, offsetBy: length)
            var bold = AttributeContainer()
            bold.font = Font.body.weight(.semibold)
            result[lower..<upper].mergeAttributes(bold)
        }
        return result
    }
}

struct StenographerNoteRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(label: "S", color: Theme.stenographer, systemImage: "text.book.closed.fill")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("@stenographer").font(.caption.weight(.semibold))
                    if let cited = message.citedEntryId {
                        Text(cited)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Theme.stenographer.opacity(0.15)))
                    }
                    Label("Only you", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                MessageText(text: message.text)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.stenographer.opacity(0.1)))
            }
            Spacer(minLength: 60)
        }
    }
}

/// "Delivered — waiting for @instrument-62…", with the agent's current tool.
struct WaitingIndicator: View {
    @Environment(MessengerModel.self) private var model
    let conversationId: String

    var body: some View {
        let waiting = Array(model.awaiting[conversationId] ?? []).sorted()
        if !waiting.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Delivered — waiting for " + waiting.map(name).joined(separator: ", ") + "…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    private func name(_ id: String) -> String {
        if id == Handles.stenographer { return "@stenographer" }
        guard let agent = model.agent(id) else { return "an agent" }
        if let tool = model.agentActivity[id] ?? model.liveActivity[id]?.current?.label {
            return "@\(agent.handle) (\(tool))"
        }
        return "@\(agent.handle)"
    }
}
