import Foundation

// MARK: - Log File Discovery

/// Find all JSONL session log files under the Claude projects directory.
/// If logDir is empty, auto-detects from ~/.claude/projects/.
public func discoverLogFiles(_ logDir: String) -> [String] {
    let fm = FileManager.default
    let searchDir: String
    if logDir.isEmpty {
        searchDir = fm.homeDirectoryForCurrentUser.path + "/.claude/projects"
    } else {
        searchDir = logDir
    }

    guard fm.fileExists(atPath: searchDir) else { return [] }

    var files: [String] = []
    walkDirectory(searchDir, results: &files)
    return files
}

private func walkDirectory(_ dir: String, results: inout [String]) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

    for entry in entries {
        let fullPath = (dir as NSString).appendingPathComponent(entry)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

        if isDir.boolValue {
            walkDirectory(fullPath, results: &results)
        } else if entry.hasSuffix(".jsonl") {
            results.append(fullPath)
        }
    }
}

// MARK: - JSONL Log Parsing

/// Internal struct for parsing log entries.
private struct LogEntry: Decodable {
    let type: String?
    let message: LogMessage?
    let sessionId: String?
    let timestamp: String?

    struct LogMessage: Decodable {
        let role: String
        let content: [ContentItem]?
    }
}

/// Represents a content item in a log message.
private enum ContentItem: Decodable {
    case toolUse(id: String, name: String)
    case toolResult(toolUseId: String, isError: Bool, content: String?)
    case other

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case toolUseId = "tool_use_id"
        case isError = "is_error"
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""

        switch type {
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            self = .toolUse(id: id, name: name)
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            let content = try container.decodeIfPresent(String.self, forKey: .content)
            self = .toolResult(toolUseId: toolUseId, isError: isError, content: content)
        default:
            self = .other
        }
    }
}

/// Parse a single JSONL session log and extract tool usage records.
public func analyzeSessionLog(_ logPath: String) -> [ToolUsageRecord] {
    guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
        return []
    }

    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    var records: [ToolUsageRecord] = []
    let decoder = JSONDecoder()

    // Track pending tool calls
    struct PendingCall {
        let toolName: String
        let timestamp: String
        let sessionId: String
    }
    var pendingCalls: [String: PendingCall] = [:]

    // Track sequence for switch-away detection
    struct SequenceItem {
        let toolName: String
        let success: Bool
    }
    var toolCallSequence: [SequenceItem] = []
    var sessionId = ""

    for line in lines {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(LogEntry.self, from: data) else {
            continue
        }

        if let sid = entry.sessionId, sessionId.isEmpty {
            sessionId = sid
        }

        guard let message = entry.message, let contentItems = message.content else { continue }

        // Process tool_use entries (assistant messages)
        if message.role == "assistant" {
            for item in contentItems {
                if case .toolUse(let id, let name) = item {
                    pendingCalls[id] = PendingCall(
                        toolName: name,
                        timestamp: entry.timestamp ?? ISO8601DateFormatter().string(from: Date()),
                        sessionId: entry.sessionId ?? sessionId
                    )
                }
            }
        }

        // Process tool_result entries (user messages)
        if message.role == "user" {
            for item in contentItems {
                if case .toolResult(let toolUseId, let isError, let resultContent) = item,
                   let pending = pendingCalls[toolUseId] {
                    pendingCalls.removeValue(forKey: toolUseId)

                    let success = !isError && !isErrorContent(resultContent)

                    toolCallSequence.append(SequenceItem(
                        toolName: pending.toolName,
                        success: success
                    ))

                    records.append(ToolUsageRecord(
                        toolName: pending.toolName,
                        timestamp: pending.timestamp,
                        success: success,
                        userSwitchedAway: false,
                        sessionId: pending.sessionId
                    ))
                }
            }
        }
    }

    // Post-process: detect switch-away patterns
    for i in 0..<(toolCallSequence.count - 1) {
        let current = toolCallSequence[i]
        let next = toolCallSequence[i + 1]

        if !current.success && current.toolName != next.toolName {
            // Find the corresponding record and mark it
            if let recordIndex = records[i...].firstIndex(where: { $0.toolName == current.toolName && !$0.success }) {
                records[recordIndex].userSwitchedAway = true
            }
        }
    }

    return records
}

/// Heuristic: check if tool result content looks like an error.
private func isErrorContent(_ content: String?) -> Bool {
    guard let content else { return false }
    let lower = content.lowercased()
    return lower.contains("error")
        || lower.contains("failed")
        || lower.contains("exception")
        || lower.contains("permission denied")
        || lower.contains("not found")
}

// MARK: - Aggregation

/// Aggregate individual tool usage records into per-tool statistics.
public func aggregateUsageStats(_ records: [ToolUsageRecord]) -> [ToolUsageStats] {
    var byTool: [String: [ToolUsageRecord]] = [:]

    for record in records {
        let key: String
        if let providerId = record.providerId {
            key = "\(providerId).\(record.toolName)"
        } else {
            key = record.toolName
        }
        byTool[key, default: []].append(record)
    }

    var stats: [ToolUsageStats] = []

    for (_, toolRecords) in byTool {
        guard let first = toolRecords.first else { continue }
        let totalCalls = toolRecords.count
        let successCount = toolRecords.filter(\.success).count
        let failureCount = totalCalls - successCount
        let switchAwayCount = toolRecords.filter(\.userSwitchedAway).count

        let durations = toolRecords.compactMap(\.durationMs)
        let avgDuration: Double? = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)

        stats.append(ToolUsageStats(
            toolName: first.toolName,
            providerId: first.providerId,
            totalCalls: totalCalls,
            successCount: successCount,
            failureCount: failureCount,
            switchAwayCount: switchAwayCount,
            successRate: totalCalls > 0 ? Double(successCount) / Double(totalCalls) : 0,
            avgDurationMs: avgDuration
        ))
    }

    // Sort by total calls descending
    stats.sort { $0.totalCalls > $1.totalCalls }

    return stats
}
