import Foundation

// MARK: - Claude Code stream-json
//
// `claude -p --output-format stream-json --verbose` emits one JSON object
// per line. We only need a handful of shapes; everything else is `.other`
// so a CLI upgrade that adds event types can't break parsing.

public enum StreamEvent: Sendable, Equatable {
    /// `system/init` — the session id is known from here on.
    case initialized(sessionId: String, model: String?)
    /// Top-level assistant prose (subagent output is filtered out).
    case assistantText(String)
    /// The assistant invoked a tool (name only — for activity display).
    case toolUse(name: String, input: [String: String])
    /// A user-role message's text (tool results excluded) — this is where a
    /// cross-session message delivered to a headless session appears.
    case userText(String)
    /// Final result of the turn.
    case result(text: String?, isError: Bool, sessionId: String?, costUSD: Double?)
    /// Informational `system` notices (e.g. a peer held or refused a message).
    case notice(String)
    case other
}

public enum StreamJSON {
    public static func parse(line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "system":
            let subtype = obj["subtype"] as? String
            if subtype == "init" {
                guard let id = obj["session_id"] as? String else { return .other }
                return .initialized(sessionId: id, model: obj["model"] as? String)
            }
            for key in ["message", "text", "content"] {
                if let text = obj[key] as? String, !text.isEmpty { return .notice(text) }
            }
            return .other

        case "assistant":
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return .other }
            guard let message = obj["message"] as? [String: Any] else { return .other }
            let blocks = message["content"] as? [[String: Any]] ?? []
            var text = ""
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    text += (text.isEmpty ? "" : "\n") + ((block["text"] as? String) ?? "")
                case "tool_use":
                    if text.isEmpty {
                        let name = (block["name"] as? String) ?? "tool"
                        var input: [String: String] = [:]
                        for (k, v) in (block["input"] as? [String: Any]) ?? [:] {
                            if let s = v as? String { input[k] = s } else if let b = v as? Bool { input[k] = String(b) }
                        }
                        return .toolUse(name: name, input: input)
                    }
                default:
                    continue
                }
            }
            return text.isEmpty ? .other : .assistantText(text)

        case "user":
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return .other }
            guard let message = obj["message"] as? [String: Any] else { return .other }
            if let text = message["content"] as? String { return .userText(text) }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? .other : .userText(texts.joined(separator: "\n"))

        case "result":
            return .result(
                text: obj["result"] as? String,
                isError: (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false),
                sessionId: obj["session_id"] as? String,
                costUSD: obj["total_cost_usd"] as? Double
            )

        default:
            return .other
        }
    }

    /// One `--input-format stream-json` user message line.
    public static func userMessageLine(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
