import Foundation

// MARK: - Persistence
//
// Everything smallchat owns (handles, archive flags, conversations,
// settings) lives in one JSON file. Claude Code's own files are only ever
// read.

/// What smallchat remembers about a session between launches.
public struct AgentRecord: Sendable, Equatable, Codable {
    public var handle: String
    public var archived: Bool
    /// Last known working directory — keeps sessions created here visible
    /// before their transcript is scanned.
    public var cwd: String?
    public var createdAt: Date

    public init(handle: String, archived: Bool = false, cwd: String? = nil, createdAt: Date = Date()) {
        self.handle = handle
        self.archived = archived
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

public struct MessengerSettings: Sendable, Equatable, Codable {
    /// Explicit path to the `claude` binary; nil probes the usual locations.
    public var claudePath: String?
    /// Wiki truth-ledger JSONL files or directories to preload the stenographer from.
    public var wikiPaths: [String]
    public var switchboardModel: String
    public var stenographerModel: String
    /// Run the passive watcher on every message.
    public var stenographerWatching: Bool
    /// Hide stopped sessions idle longer than this many days (nil shows all).
    public var recentDays: Int?

    public init(
        claudePath: String? = nil,
        wikiPaths: [String] = [],
        switchboardModel: String = "haiku",
        stenographerModel: String = "sonnet",
        stenographerWatching: Bool = true,
        recentDays: Int? = 30
    ) {
        self.claudePath = claudePath
        self.wikiPaths = wikiPaths
        self.switchboardModel = switchboardModel
        self.stenographerModel = stenographerModel
        self.stenographerWatching = stenographerWatching
        self.recentDays = recentDays
    }
}

public struct MessengerSnapshot: Sendable, Equatable, Codable {
    public var agents: [String: AgentRecord]
    public var conversations: [Conversation]
    /// Conversation id → the stenographer's own Claude session for that chat.
    public var stenographerSessions: [String: String]
    public var settings: MessengerSettings

    public init(
        agents: [String: AgentRecord] = [:],
        conversations: [Conversation] = [],
        stenographerSessions: [String: String] = [:],
        settings: MessengerSettings = MessengerSettings()
    ) {
        self.agents = agents
        self.conversations = conversations
        self.stenographerSessions = stenographerSessions
        self.settings = settings
    }
}

public struct MessengerStore: Sendable {
    public let url: URL?

    /// `url == nil` keeps everything in memory (previews, tests).
    public init(url: URL?) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".smallchat")
        return base.appendingPathComponent("SmallChat", isDirectory: true).appendingPathComponent("messenger.json")
    }

    public func load() -> MessengerSnapshot {
        guard let url, let data = try? Data(contentsOf: url) else { return MessengerSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MessengerSnapshot.self, from: data)) ?? MessengerSnapshot()
    }

    public func save(_ snapshot: MessengerSnapshot) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
