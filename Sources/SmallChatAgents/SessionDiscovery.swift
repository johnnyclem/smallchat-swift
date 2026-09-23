import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Session discovery
//
// Two on-disk sources, both written by Claude Code:
//
//   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl   transcripts (every session)
//   ~/.claude/sessions/<pid>.json                          live-session registry
//
// Neither format is a public contract (the docs say the transcript format
// "changes between versions"), so everything here decodes defensively:
// every field optional, unknown lines skipped, a bad file never fails the scan.

/// One row of Claude Code's live-session registry.
public struct LiveSessionRecord: Sendable, Equatable, Decodable {
    public var pid: Int32?
    public var sessionId: String?
    public var cwd: String?
    public var kind: String?
    public var name: String?
    /// "derived" when Claude Code generated the name; anything else is user-chosen.
    public var nameSource: String?
    public var status: String?
    public var messagingSocketPath: String?
    /// Epoch milliseconds.
    public var updatedAt: Double?

    public init(
        pid: Int32? = nil, sessionId: String? = nil, cwd: String? = nil, kind: String? = nil,
        name: String? = nil, nameSource: String? = nil, status: String? = nil,
        messagingSocketPath: String? = nil, updatedAt: Double? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.messagingSocketPath = messagingSocketPath
        self.updatedAt = updatedAt
    }

    public var activity: AgentActivity {
        switch status?.lowercased() {
        case "busy", "running", "working": return .busy
        default: return .idle
        }
    }

    public var agentKind: AgentKind {
        switch kind?.lowercased() {
        case "interactive": return .interactive
        case "background", "bg": return .background
        case "headless", "print", "sdk": return .headless
        default: return .unknown
        }
    }

    public var nameIsUserChosen: Bool {
        guard let nameSource, name != nil else { return false }
        return nameSource.lowercased() != "derived"
    }
}

/// What we can learn about a session from its transcript without reading all of it.
public struct TranscriptSummary: Sendable, Equatable {
    public var sessionId: String
    public var path: String
    public var cwd: String?
    public var gitBranch: String?
    public var aiTitle: String?
    public var customTitle: String?
    public var lastPrompt: String?
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?

    public var title: String? { customTitle ?? aiTitle ?? lastPrompt }
}

/// A session found on disk: transcript, live record, or both.
public struct DiscoveredSession: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var gitBranch: String?
    public var title: String?
    public var lastActivity: Date
    public var transcriptPath: String?
    public var live: LiveSessionRecord?
}

public struct ClaudeSessionScanner: Sendable {
    /// Claude Code's config directory (`~/.claude`, or `$CLAUDE_CONFIG_DIR`).
    public var claudeHome: URL
    /// Bytes read from each end of a transcript.
    public var windowBytes: Int = 128 * 1024
    /// Liveness probe for registry pids (injectable for tests).
    public var isProcessAlive: @Sendable (Int32) -> Bool = ClaudeSessionScanner.processAlive

    public init(claudeHome: URL = ClaudeSessionScanner.defaultClaudeHome()) {
        self.claudeHome = claudeHome
    }

    public static func defaultClaudeHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    @Sendable public static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Scan

    public func scan() -> [DiscoveredSession] {
        let live = liveRecords()
        let transcripts = transcriptSummaries()

        var byId: [String: DiscoveredSession] = [:]
        for t in transcripts {
            byId[t.sessionId] = DiscoveredSession(
                sessionId: t.sessionId,
                cwd: t.cwd ?? "",
                gitBranch: t.gitBranch,
                title: t.title,
                lastActivity: t.lastTimestamp ?? t.firstTimestamp ?? .distantPast,
                transcriptPath: t.path,
                live: nil
            )
        }
        for record in live {
            guard let id = record.sessionId else { continue }
            let updated = record.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if var existing = byId[id] {
                existing.live = record
                if existing.cwd.isEmpty, let cwd = record.cwd { existing.cwd = cwd }
                if let updated, updated > existing.lastActivity { existing.lastActivity = updated }
                byId[id] = existing
            } else {
                byId[id] = DiscoveredSession(
                    sessionId: id,
                    cwd: record.cwd ?? "",
                    gitBranch: nil,
                    title: nil,
                    lastActivity: updated ?? Date(),
                    transcriptPath: nil,
                    live: record
                )
            }
        }
        return byId.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Registry rows whose process is still alive, newest first per session.
    public func liveRecords() -> [LiveSessionRecord] {
        let dir = claudeHome.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        var bySession: [String: LiveSessionRecord] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(LiveSessionRecord.self, from: data),
                  let sessionId = record.sessionId else { continue }
            if let pid = record.pid, !isProcessAlive(pid) { continue }
            if let existing = bySession[sessionId], (existing.updatedAt ?? 0) >= (record.updatedAt ?? 0) { continue }
            bySession[sessionId] = record
        }
        return Array(bySession.values)
    }

    /// Top-level transcripts in every project directory. Subagent
    /// transcripts live in nested directories and are skipped.
    public func transcriptSummaries() -> [TranscriptSummary] {
        let projects = claudeHome.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [TranscriptSummary] = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let summary = summarize(transcriptAt: file) { out.append(summary) }
            }
        }
        return out
    }

    public func summarize(transcriptAt url: URL) -> TranscriptSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: windowBytes)) ?? Data()
        var tail = Data()
        if size > UInt64(windowBytes) {
            try? handle.seek(toOffset: size - UInt64(windowBytes))
            tail = (try? handle.read(upToCount: windowBytes)) ?? Data()
        }

        let fallbackId = url.deletingPathExtension().lastPathComponent
        var summary = TranscriptSummary(sessionId: fallbackId, path: url.path)
        Self.absorb(lines: Self.lines(head, dropPartialFirst: false, dropPartialLast: size > UInt64(windowBytes)), into: &summary)
        if !tail.isEmpty {
            Self.absorb(lines: Self.lines(tail, dropPartialFirst: true, dropPartialLast: false), into: &summary)
        }
        return summary
    }

    static func lines(_ data: Data, dropPartialFirst: Bool, dropPartialLast: Bool) -> [Substring] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropPartialFirst, !lines.isEmpty { lines.removeFirst() }
        if dropPartialLast, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// Fold transcript lines into a summary. Later lines win for titles and
    /// the last timestamp; the first cwd/timestamp seen is kept.
    static func absorb(lines: [Substring], into summary: inout TranscriptSummary) {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if let id = obj["sessionId"] as? String, !id.isEmpty, summary.sessionId != id,
               UUID(uuidString: summary.sessionId) == nil {
                summary.sessionId = id
            }
            switch type {
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.isEmpty { summary.aiTitle = t }
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { summary.customTitle = t }
            case "summary":
                if summary.aiTitle == nil, let t = obj["summary"] as? String, !t.isEmpty { summary.aiTitle = t }
            case "last-prompt":
                if let t = obj["lastPrompt"] as? String, !t.isEmpty { summary.lastPrompt = t }
            default:
                break
            }
            if (obj["isSidechain"] as? Bool) == true { continue }
            if summary.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { summary.cwd = cwd }
            if let branch = obj["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { summary.gitBranch = branch }
            if let ts = (obj["timestamp"] as? String).flatMap(parseISODate) {
                if summary.firstTimestamp == nil || ts < summary.firstTimestamp! { summary.firstTimestamp = ts }
                if summary.lastTimestamp == nil || ts > summary.lastTimestamp! { summary.lastTimestamp = ts }
            }
        }
    }
}

// MARK: - Dates

/// Parse ISO-8601 with or without fractional seconds.
public func parseISODate(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fractional.date(from: string) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}
