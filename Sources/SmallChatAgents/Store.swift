import Foundation

// MARK: - Persistence
//
// Everything smallchat owns (handles, archive flags, conversations,
// settings) lives in one JSON file, except its secrets, which live in a
// `MessengerSecretStore` (see Secrets.swift). Claude Code's own files are
// only ever read.

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
    /// Run the loopback bridge stenographer's `--objection-channel` posts to.
    public var objectionChannelEnabled: Bool
    public var objectionChannelPort: Int
    /// Relay each objection into the offending agent's live session.
    public var relayObjections: Bool
    /// Who you sign tombstones as (an accountable identity, not "system").
    public var signerIdentity: String
    /// Wiki JSONL file new tombstones are appended to (nil: first configured file).
    public var tombstoneFile: String?
    /// Stenographer's REST port (`--rest-port`), where agent drafts are notarized.
    public var stenographerRestPort: Int

    /// Set when the decoded JSON still held the channel secret an older build
    /// stored there, so the messenger rewrites the file without it. Never encoded.
    var carriesLegacySecret = false

    public static let defaultObjectionChannelPort = 7337
    public static let defaultStenographerRestPort = 8787

    public init(
        claudePath: String? = nil,
        wikiPaths: [String] = [],
        switchboardModel: String = "haiku",
        stenographerModel: String = "sonnet",
        stenographerWatching: Bool = true,
        recentDays: Int? = 30,
        objectionChannelEnabled: Bool = true,
        objectionChannelPort: Int = MessengerSettings.defaultObjectionChannelPort,
        relayObjections: Bool = true,
        signerIdentity: String = "",
        tombstoneFile: String? = nil,
        stenographerRestPort: Int = MessengerSettings.defaultStenographerRestPort
    ) {
        self.claudePath = claudePath
        self.wikiPaths = wikiPaths
        self.switchboardModel = switchboardModel
        self.stenographerModel = stenographerModel
        self.stenographerWatching = stenographerWatching
        self.recentDays = recentDays
        self.objectionChannelEnabled = objectionChannelEnabled
        self.objectionChannelPort = objectionChannelPort
        self.relayObjections = relayObjections
        self.signerIdentity = signerIdentity
        self.tombstoneFile = tombstoneFile
        self.stenographerRestPort = stenographerRestPort
    }

    enum CodingKeys: String, CodingKey {
        case claudePath, wikiPaths, switchboardModel, stenographerModel, stenographerWatching, recentDays
        case objectionChannelEnabled, objectionChannelPort, relayObjections
        case signerIdentity, tombstoneFile, stenographerRestPort
        /// Read only to notice a secret older builds stored here.
        case legacyObjectionChannelSecret = "objectionChannelSecret"
    }

    /// Lenient: settings saved by an older build (missing newer keys) still
    /// load. A strict decode failure would drop the whole store, conversations
    /// included.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MessengerSettings()
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        wikiPaths = try c.decodeIfPresent([String].self, forKey: .wikiPaths) ?? defaults.wikiPaths
        switchboardModel = try c.decodeIfPresent(String.self, forKey: .switchboardModel) ?? defaults.switchboardModel
        stenographerModel = try c.decodeIfPresent(String.self, forKey: .stenographerModel) ?? defaults.stenographerModel
        stenographerWatching = try c.decodeIfPresent(Bool.self, forKey: .stenographerWatching) ?? defaults.stenographerWatching
        // Explicit null means "all time"; a missing key means "default".
        recentDays = c.contains(.recentDays) ? try c.decodeIfPresent(Int.self, forKey: .recentDays) : defaults.recentDays
        objectionChannelEnabled = try c.decodeIfPresent(Bool.self, forKey: .objectionChannelEnabled) ?? defaults.objectionChannelEnabled
        objectionChannelPort = try c.decodeIfPresent(Int.self, forKey: .objectionChannelPort) ?? defaults.objectionChannelPort
        carriesLegacySecret = c.contains(.legacyObjectionChannelSecret)
        relayObjections = try c.decodeIfPresent(Bool.self, forKey: .relayObjections) ?? defaults.relayObjections
        signerIdentity = try c.decodeIfPresent(String.self, forKey: .signerIdentity) ?? defaults.signerIdentity
        tombstoneFile = try c.decodeIfPresent(String.self, forKey: .tombstoneFile)
        stenographerRestPort = try c.decodeIfPresent(Int.self, forKey: .stenographerRestPort) ?? defaults.stenographerRestPort
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claudePath, forKey: .claudePath)
        try c.encode(wikiPaths, forKey: .wikiPaths)
        try c.encode(switchboardModel, forKey: .switchboardModel)
        try c.encode(stenographerModel, forKey: .stenographerModel)
        try c.encode(stenographerWatching, forKey: .stenographerWatching)
        try c.encode(recentDays, forKey: .recentDays)  // null = all time
        try c.encode(objectionChannelEnabled, forKey: .objectionChannelEnabled)
        try c.encode(objectionChannelPort, forKey: .objectionChannelPort)
        try c.encode(relayObjections, forKey: .relayObjections)
        try c.encode(signerIdentity, forKey: .signerIdentity)
        try c.encodeIfPresent(tombstoneFile, forKey: .tombstoneFile)
        try c.encode(stenographerRestPort, forKey: .stenographerRestPort)
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
    /// Where the channel and notary secrets live (never in the JSON file).
    public let secrets: any MessengerSecretStore

    /// `url == nil` keeps everything in memory (previews, tests). Without
    /// `secrets`, a store with a file keeps its secrets in the platform's
    /// store: the Keychain on macOS, elsewhere 0600 files in a `secrets`
    /// directory beside the file.
    public init(url: URL?, secrets: (any MessengerSecretStore)? = nil) {
        self.url = url
        self.secrets = secrets ?? url.map {
            MessengerSecretStores.platformDefault(
                fileDirectory: $0.deletingLastPathComponent().appendingPathComponent("secrets", isDirectory: true)
            )
        } ?? InMemorySecretStore()
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
