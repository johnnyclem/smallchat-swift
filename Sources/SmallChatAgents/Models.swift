import Foundation

// MARK: - Agent sessions

/// Whether a Claude Code session is doing something right now.
public enum AgentActivity: String, Sendable, Codable, Equatable {
    /// Live and mid-turn.
    case busy
    /// Live and waiting for input.
    case idle
    /// No live process — reachable only by headless resume.
    case stopped
}

/// How the session was launched (mirrors Claude Code's registry `kind`).
public enum AgentKind: String, Sendable, Codable, Equatable {
    case interactive
    case background
    case headless
    case unknown
}

/// One Claude Code session as smallchat sees it: transcript on disk,
/// optionally a live process, and the durable handle the user addresses
/// it by.
public struct AgentSession: Sendable, Equatable, Identifiable, Codable {
    /// Claude Code's session UUID — the stable identity.
    public let id: String
    /// Durable, user-renamable handle (`@handle`). Unique across the directory.
    public var handle: String
    /// The name Claude Code itself answers to for `SendMessage`, when known.
    /// Differs from `handle` until the session is renamed at its own keyboard.
    public var claudeName: String?
    /// Working directory the session runs in.
    public var cwd: String
    public var gitBranch: String?
    /// Claude's own title for the conversation (`ai-title` / `custom-title`).
    public var title: String?
    public var lastActivity: Date
    public var activity: AgentActivity
    public var kind: AgentKind
    public var archived: Bool
    /// Path of the transcript JSONL, when found.
    public var transcriptPath: String?

    public init(
        id: String,
        handle: String,
        claudeName: String? = nil,
        cwd: String,
        gitBranch: String? = nil,
        title: String? = nil,
        lastActivity: Date,
        activity: AgentActivity = .stopped,
        kind: AgentKind = .unknown,
        archived: Bool = false,
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.handle = handle
        self.claudeName = claudeName
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.lastActivity = lastActivity
        self.activity = activity
        self.kind = kind
        self.archived = archived
        self.transcriptPath = transcriptPath
    }

    /// Last path component of the working directory ("instrument").
    public var project: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    public var isLive: Bool { activity != .stopped }
}

// MARK: - Conversations

public enum ConversationKind: String, Sendable, Codable, Equatable {
    /// You and one agent.
    case direct
    /// You and one or more agents; your messages fan out to every member.
    case group
}

public struct Conversation: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var kind: ConversationKind
    /// Display name. For direct chats this tracks the agent's handle.
    public var title: String
    /// Session ids of the agent members.
    public var memberIds: [String]
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: ConversationKind,
        title: String,
        memberIds: [String],
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.memberIds = memberIds
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Messages

public enum MessageAuthor: Sendable, Equatable, Codable, Hashable {
    /// The human at the keyboard.
    case user
    /// An agent, by session id.
    case agent(String)
    /// The stenographer watching the chat.
    case stenographer
    /// Delivery notices, errors, and other app-generated lines.
    case system
}

/// Who can see an agent's message. Agent replies land private-to-you;
/// sharing promotes them to the group (delivered as an interrupt).
public enum MessageVisibility: String, Sendable, Codable, Equatable {
    /// Seen by everyone in the conversation.
    case group
    /// Seen only by you. Agent replies start here in a group chat.
    case privateToUser
}

public enum DeliveryState: Sendable, Equatable, Codable {
    case pending
    /// Handed to the transport; waiting on the recipient(s).
    case delivered
    /// Recipient's inbound controls held the message for approval.
    case held(String)
    case failed(String)
}

public struct ChatMessage: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var author: MessageAuthor
    public var text: String
    public var timestamp: Date
    public var visibility: MessageVisibility
    /// Session ids this message was (or will be) delivered to.
    public var recipients: [String]
    public var delivery: DeliveryState
    /// True once you've decided on a private agent reply (shared or kept).
    public var shareDecided: Bool
    /// Set on stenographer notes: the TB/UV id cited.
    public var citedEntryId: String?

    public init(
        id: String = UUID().uuidString,
        author: MessageAuthor,
        text: String,
        timestamp: Date = Date(),
        visibility: MessageVisibility = .group,
        recipients: [String] = [],
        delivery: DeliveryState = .delivered,
        shareDecided: Bool = false,
        citedEntryId: String? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
        self.visibility = visibility
        self.recipients = recipients
        self.delivery = delivery
        self.shareDecided = shareDecided
        self.citedEntryId = citedEntryId
    }

    /// A private agent reply you haven't shared or kept yet.
    public var awaitingShareDecision: Bool {
        if case .agent = author, visibility == .privateToUser, !shareDecided { return true }
        return false
    }
}

// MARK: - Objection channel

public enum ObjectionChannelStatus: Sendable, Equatable {
    case off
    case listening(port: Int)
    case failed(String)

    public var port: Int? {
        if case .listening(let port) = self { return port }
        return nil
    }
}

/// An objection stenographer pushed over the channel.
public struct ReceivedObjection: Sendable, Equatable, Identifiable {
    public let id: String
    public let objectionIds: [String]
    public let tbIds: [String]
    /// Claude Code session ids named by the objection.
    public let sessionIds: [String]
    public let content: String
    public let receivedAt: Date
    /// Agents whose chats it was posted to (empty: no known session matched).
    public let routedTo: [String]
    /// Agents it was relayed into as an interrupt.
    public let relayedTo: [String]

    public init(
        objectionIds: [String], tbIds: [String], sessionIds: [String], content: String,
        receivedAt: Date = Date(), routedTo: [String], relayedTo: [String]
    ) {
        self.id = objectionIds.isEmpty ? UUID().uuidString : objectionIds.joined(separator: ",")
        self.objectionIds = objectionIds
        self.tbIds = tbIds
        self.sessionIds = sessionIds
        self.content = content
        self.receivedAt = receivedAt
        self.routedTo = routedTo
        self.relayedTo = relayedTo
    }
}

/// A tombstone an agent drafted (stenographer `propose_tombstone`) that only
/// the user can turn into truth.
public struct PendingProposal: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case awaiting
        case working
        case notarized(entryId: String?)
        case declined
        case failed(String)

        public var isOpen: Bool {
            switch self {
            case .awaiting, .failed: return true
            case .working, .notarized, .declined: return false
            }
        }
    }

    /// Stenographer's proposal id.
    public let id: String
    public let draftedBy: String
    /// Claude Code session ids of the drafting agent.
    public let sessionIds: [String]
    /// The notice as stenographer wrote it: claim, literals, rationale.
    public let content: String
    public let notarizeURL: URL?
    public let receivedAt: Date
    public var state: State

    public init(
        id: String, draftedBy: String, sessionIds: [String], content: String,
        notarizeURL: URL?, receivedAt: Date = Date(), state: State = .awaiting
    ) {
        self.id = id
        self.draftedBy = draftedBy
        self.sessionIds = sessionIds
        self.content = content
        self.notarizeURL = notarizeURL
        self.receivedAt = receivedAt
        self.state = state
    }
}
