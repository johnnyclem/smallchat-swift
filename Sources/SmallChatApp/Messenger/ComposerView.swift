import SwiftUI
import SmallChatAgents

/// Message box with @mention autocomplete. Return (or ⌘Return) sends;
/// Tab accepts the first suggestion.
struct ComposerView: View {
    @Environment(MessengerModel.self) private var model
    let conversation: Conversation
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { handle in
                            Button {
                                accept(handle)
                            } label: {
                                Text("@\(handle)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(color(for: handle).opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        accept(first)
                        return .handled
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Theme.accent : Color.secondary)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘Return)")
            }
            Text(routingHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        conversation.kind == .group ? "Message \(conversation.title)…" : "Message @\(conversation.title)…"
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestions: [String] {
        guard let query = MentionParser.activeQuery(in: draft) else { return [] }
        return model.mentionSuggestions(for: query, in: conversation.id)
    }

    /// Live preview of who the draft will reach.
    private var routingHint: String {
        let parse = MentionParser.parse(draft)
        let agents = parse.handles.filter { model.agent(handle: $0) != nil }
        if parse.mentionsBroadcast { return "Goes to everyone in this chat" + (agents.isEmpty ? "" : " plus " + agents.map { "@\($0)" }.joined(separator: ", ")) }
        if !agents.isEmpty { return "Goes only to " + agents.map { "@\($0)" }.joined(separator: ", ") }
        if parse.mentionsStenographer { return "Asks the stenographer — agents won't see it" }
        if conversation.kind == .group { return "Goes to all \(conversation.memberIds.count) agents · @name to target one · @stenographer for the record" }
        return "@name loops in another agent · @stenographer asks about the record"
    }

    private func color(for handle: String) -> Color {
        handle == Handles.stenographer ? Theme.stenographer : Theme.color(for: handle)
    }

    private func accept(_ handle: String) {
        draft = MentionParser.complete(draft, with: handle)
        focused = true
    }

    private func send() {
        guard canSend else { return }
        model.send(draft, in: conversation.id)
        draft = ""
    }
}
