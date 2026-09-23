import Foundation

// MARK: - Routing
//
// Pure decisions about who receives what. No I/O: the model feeds the
// result to a transport.

/// How a message should reach a session.
public enum DeliveryStyle: String, Sendable, Equatable {
    /// The user is talking to the agent (its reply comes back to the user).
    case prompt
    /// Group traffic pushed into the agent mid-task via inter-agent
    /// messaging: arrives between tool calls, or starts a turn if idle.
    case interrupt
}

public struct Delivery: Sendable, Equatable {
    public let recipientId: String
    public let body: String
    public let style: DeliveryStyle
}

public struct RoutePlan: Sendable, Equatable {
    public var deliveries: [Delivery]
    /// The stenographer was asked something directly.
    public var asksStenographer: Bool
    /// Mentions that matched nobody (surfaced to the user, never guessed).
    public var unknownHandles: [String]
    /// Agents outside the conversation that a mention pulled in.
    public var outsideRecipients: [String]
}

public enum ChatRouter {

    /// Plan delivery of something the user typed.
    ///
    /// - No agent mentions → every member gets it.
    /// - `@handle` mentions → only the mentioned agents (members or not).
    /// - `@all` → every member, plus any other mentioned agents.
    /// - `@stenographer` alone → nobody but the stenographer.
    public static func planUserMessage(
        _ text: String,
        in conversation: Conversation,
        agents: [AgentSession]
    ) -> RoutePlan {
        let parse = MentionParser.parse(text)
        let byHandle = Dictionary(agents.map { ($0.handle, $0) }, uniquingKeysWith: { a, _ in a })

        var mentionedIds: [String] = []
        var unknown: [String] = []
        for handle in parse.handles {
            if Handles.broadcast.contains(handle) || handle == Handles.stenographer { continue }
            if let agent = byHandle[handle] {
                mentionedIds.append(agent.id)
            } else {
                unknown.append(handle)
            }
        }

        var recipientIds: [String]
        if parse.mentionsBroadcast {
            recipientIds = conversation.memberIds + mentionedIds.filter { !conversation.memberIds.contains($0) }
        } else if !mentionedIds.isEmpty {
            recipientIds = mentionedIds
        } else if parse.mentionsStenographer || !unknown.isEmpty {
            // Addressed to someone specific we couldn't reach as an agent —
            // don't silently broadcast it instead.
            recipientIds = []
        } else {
            recipientIds = conversation.memberIds
        }

        let agentsById = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let deliveries = recipientIds.compactMap { id -> Delivery? in
            guard let agent = agentsById[id] else { return nil }
            return Delivery(
                recipientId: id,
                body: frameUserMessage(text, to: agent, in: conversation, agents: agentsById),
                style: .prompt
            )
        }

        return RoutePlan(
            deliveries: deliveries,
            asksStenographer: parse.mentionsStenographer,
            unknownHandles: unknown,
            outsideRecipients: recipientIds.filter { !conversation.memberIds.contains($0) }
        )
    }

    /// Plan sharing a private agent reply with the rest of the group.
    public static func planShare(
        _ message: ChatMessage,
        in conversation: Conversation,
        agents: [AgentSession]
    ) -> [Delivery] {
        guard case .agent(let authorId) = message.author else { return [] }
        let agentsById = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let authorHandle = agentsById[authorId]?.handle ?? "agent"
        return conversation.memberIds
            .filter { $0 != authorId }
            .compactMap { id in
                guard let agent = agentsById[id] else { return nil }
                let header = "[smallchat · group “\(conversation.title)” · \(roster(conversation, agents: agentsById, you: agent)) · @\(authorHandle) shared this with the group]"
                return Delivery(recipientId: id, body: header + "\n" + message.text, style: .interrupt)
            }
    }

    // MARK: Framing

    static func frameUserMessage(
        _ text: String,
        to agent: AgentSession,
        in conversation: Conversation,
        agents: [String: AgentSession]
    ) -> String {
        switch conversation.kind {
        case .direct:
            return "[smallchat · direct message from the user · you are @\(agent.handle)]\n" + text
        case .group:
            return "[smallchat · group “\(conversation.title)” · \(roster(conversation, agents: agents, you: agent)) · from the user]\n" + text
        }
    }

    static func roster(_ conversation: Conversation, agents: [String: AgentSession], you: AgentSession) -> String {
        let others = conversation.memberIds
            .filter { $0 != you.id }
            .compactMap { agents[$0].map { "@\($0.handle)" } }
        let members = (["the user"] + others).joined(separator: ", ")
        return "members: \(members), you (@\(you.handle))"
    }
}
