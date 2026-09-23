import Foundation

// MARK: - Live tool activity
//
// What a live session is doing right now, read from the tail of its
// transcript: every `tool_use` block the assistant emits is a step, and the
// matching `tool_result` (by `tool_use_id`) finishes it. A step with no
// result yet is the one in flight. Subagent (sidechain) traffic is skipped
// so the card shows the session's own work.

public struct ActivityStep: Sendable, Equatable, Identifiable {
    /// The `tool_use` id.
    public let id: String
    public let tool: String
    /// One-line description: the command, file, pattern, or URL.
    public let summary: String
    public let startedAt: Date?
    public var finished: Bool
    public var failed: Bool

    public init(id: String, tool: String, summary: String, startedAt: Date?, finished: Bool = false, failed: Bool = false) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.startedAt = startedAt
        self.finished = finished
        self.failed = failed
    }

    /// "Bash · xcodebuild -scheme …"
    public var label: String { summary.isEmpty ? tool : "\(tool) · \(summary)" }
}

public struct ActivitySnapshot: Sendable, Equatable {
    /// The newest step still waiting for its result.
    public var current: ActivityStep?
    /// Most recent steps, oldest first (includes `current`).
    public var recent: [ActivityStep]
    /// First line of the latest assistant prose, if newer than the last step.
    public var lastSaid: String?

    public init(current: ActivityStep? = nil, recent: [ActivityStep] = [], lastSaid: String? = nil) {
        self.current = current
        self.recent = recent
        self.lastSaid = lastSaid
    }

    public var isEmpty: Bool { current == nil && recent.isEmpty && lastSaid == nil }
}

public enum TranscriptActivity {
    public static let maxRecent = 5
    static let maxSummary = 90

    /// Read the tail of a transcript and summarize its latest activity.
    public static func read(transcriptAt path: String, windowBytes: Int = 64 * 1024) -> ActivitySnapshot {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ActivitySnapshot() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(windowBytes) ? size - UInt64(windowBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial first line
        return parse(lines: lines.map(String.init))
    }

    public static func parse(lines: [String]) -> ActivitySnapshot {
        var steps: [ActivityStep] = []
        var index: [String: Int] = [:]
        var lastSaid: String?
        var saidAfterLastStep = false

        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap(parseISODate)

            switch obj["type"] as? String {
            case "assistant":
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        let tool = (block["name"] as? String) ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        index[id] = steps.count
                        steps.append(ActivityStep(id: id, tool: tool, summary: summarize(tool: tool, input: input), startedAt: timestamp))
                        saidAfterLastStep = false
                    case "text":
                        if let text = block["text"] as? String,
                           let first = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                            lastSaid = truncate(String(first).trimmingCharacters(in: .whitespaces))
                            saidAfterLastStep = true
                        }
                    default:
                        continue
                    }
                }
            case "user":
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let i = index[id] else { continue }
                    steps[i].finished = true
                    steps[i].failed = (block["is_error"] as? Bool) == true
                }
            default:
                continue
            }
        }

        let recent = Array(steps.suffix(maxRecent))
        return ActivitySnapshot(
            current: steps.last(where: { !$0.finished }),
            recent: recent,
            lastSaid: saidAfterLastStep ? lastSaid : nil
        )
    }

    /// The most informative input field per tool, falling back to the first string.
    static func summarize(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? {
            (input[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func file(_ key: String) -> String? { str(key).map { ($0 as NSString).lastPathComponent } }

        let raw: String?
        switch tool {
        case "Bash": raw = str("description") ?? str("command")
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": raw = file("file_path") ?? file("notebook_path")
        case "Grep", "Glob": raw = str("pattern")
        case "WebFetch": raw = str("url")
        case "WebSearch": raw = str("query")
        case "Task", "Agent": raw = str("description")
        case "SendMessage": raw = str("to").map { "→ \($0)" }
        default:
            raw = input.keys.sorted().lazy.compactMap { str($0) }.first
        }
        guard let raw else { return "" }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        return truncate(firstLine)
    }

    static func truncate(_ s: String) -> String {
        s.count > maxSummary ? String(s.prefix(maxSummary - 1)) + "…" : s
    }
}
