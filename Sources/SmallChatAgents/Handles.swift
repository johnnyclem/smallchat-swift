import Foundation

// MARK: - Handles
//
// A handle is the durable, human-readable name the user addresses an agent
// by (`@instrument-62`). It survives restarts (persisted in the directory),
// is unique, and the user can rename it. Handles use the same character set
// Claude Code accepts unquoted in an @-mention: letters, digits, `-`, `_`.

public enum HandleError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooLong(max: Int)
    case invalidCharacters
    case reserved(String)
    case taken(String)

    public var description: String {
        switch self {
        case .empty: return "Name can't be empty."
        case .tooLong(let max): return "Name must be \(max) characters or fewer."
        case .invalidCharacters: return "Use letters, digits, - and _ only, starting with a letter or digit."
        case .reserved(let name): return "@\(name) is reserved."
        case .taken(let name): return "@\(name) is already in use."
        }
    }
}

public enum Handles {
    public static let maxLength = 32
    /// The stenographer's fixed handle.
    public static let stenographer = "stenographer"
    /// Mentions that address every agent in the conversation.
    public static let broadcast: Set<String> = ["all", "group", "everyone"]
    /// Names no agent may take.
    public static let reserved: Set<String> = broadcast.union(["you", "me", "user", "smallchat", "system", stenographer])

    static func isHandleCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// Canonical form used for comparison and storage (lowercased).
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        return s.lowercased()
    }

    /// Validate a proposed handle. `taken` holds the normalized handles of
    /// every *other* agent.
    public static func validate(_ raw: String, taken: Set<String>) throws -> String {
        let handle = normalize(raw)
        guard !handle.isEmpty else { throw HandleError.empty }
        guard handle.count <= maxLength else { throw HandleError.tooLong(max: maxLength) }
        guard let first = handle.first, first.isLetter || first.isNumber,
              handle.allSatisfy(isHandleCharacter) else { throw HandleError.invalidCharacters }
        guard !reserved.contains(handle) else { throw HandleError.reserved(handle) }
        guard !taken.contains(handle) else { throw HandleError.taken(handle) }
        return handle
    }

    /// Turn arbitrary text ("My Project (v2)") into handle characters ("my-project-v2").
    public static func slugify(_ text: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in text.lowercased().unicodeScalars {
            let c = Character(scalar)
            if c.isASCII && (c.isLetter || c.isNumber || c == "_") {
                out.append(c)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Suggest a handle for a newly discovered session.
    ///
    /// A name the user deliberately gave the session in Claude Code (`/rename`,
    /// `--name`) wins. Otherwise: project slug + a short slice of the session
    /// id (`instrument-62`), lengthening the slice until it's unique.
    public static func suggest(
        sessionId: String,
        cwd: String,
        claudeName: String?,
        claudeNameIsUserChosen: Bool,
        taken: Set<String>
    ) -> String {
        if claudeNameIsUserChosen, let claudeName {
            let slug = String(slugify(claudeName).prefix(maxLength))
            if (try? validate(slug, taken: taken)) != nil { return slug }
        }

        var base = slugify((cwd as NSString).lastPathComponent)
        if base.isEmpty || !(base.first?.isLetter ?? false) { base = "agent" + (base.isEmpty ? "" : "-" + base) }
        let hex = sessionId.lowercased().filter { $0.isHexDigit }
        let suffixSource = hex.isEmpty ? slugify(sessionId) : hex

        for length in 2...max(2, suffixSource.count) {
            let suffix = String(suffixSource.prefix(length))
            let candidate = String(base.prefix(maxLength - suffix.count - 1)) + "-" + suffix
            if (try? validate(candidate, taken: taken)) != nil { return candidate }
        }
        // Fully colliding ids (shouldn't happen) — number it.
        var n = 2
        while true {
            let candidate = "\(String(base.prefix(maxLength - 4)))-\(n)"
            if (try? validate(candidate, taken: taken)) != nil { return candidate }
            n += 1
        }
    }
}

// MARK: - Mentions

public struct Mention: Sendable, Equatable {
    /// Normalized handle as typed (without `@`).
    public let handle: String
    /// UTF-16 range of the whole token including `@` (for highlighting in text views).
    public let range: NSRange
}

public struct MentionParse: Sendable, Equatable {
    public var mentions: [Mention]

    /// Normalized handles, deduplicated, in order of first appearance.
    public var handles: [String] {
        var seen = Set<String>()
        return mentions.map(\.handle).filter { seen.insert($0).inserted }
    }

    public var mentionsBroadcast: Bool { mentions.contains { Handles.broadcast.contains($0.handle) } }
    public var mentionsStenographer: Bool { mentions.contains { $0.handle == Handles.stenographer } }
}

public enum MentionParser {
    /// Find `@handle` and `@"quoted name"` tokens. An `@` preceded by a
    /// handle character (as in `me@example.com`) is not a mention.
    public static func parse(_ text: String) -> MentionParse {
        var mentions: [Mention] = []
        let utf16 = Array(text.utf16)
        let at = UInt16(UInt8(ascii: "@"))
        let quote = UInt16(UInt8(ascii: "\""))

        func isHandleUnit(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
                || u == 0x2D || u == 0x5F
        }

        var i = 0
        while i < utf16.count {
            guard utf16[i] == at else { i += 1; continue }
            if i > 0, isHandleUnit(utf16[i - 1]) || utf16[i - 1] == at { i += 1; continue }

            if i + 1 < utf16.count, utf16[i + 1] == quote {
                // @"quoted name" — ends at the next quote on the same line.
                var j = i + 2
                while j < utf16.count, utf16[j] != quote, utf16[j] != 0x0A { j += 1 }
                if j < utf16.count, utf16[j] == quote, j > i + 2 {
                    let name = String(decoding: utf16[(i + 2)..<j], as: UTF16.self)
                    mentions.append(Mention(
                        handle: Handles.normalize(name),
                        range: NSRange(location: i, length: j + 1 - i)
                    ))
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }

            var j = i + 1
            while j < utf16.count, isHandleUnit(utf16[j]) { j += 1 }
            // Trailing '-' / '_' are punctuation ("ping @bob-"), not part of the handle.
            var end = j
            while end > i + 1, utf16[end - 1] == 0x2D || utf16[end - 1] == 0x5F { end -= 1 }
            if end > i + 1 {
                let name = String(decoding: utf16[(i + 1)..<end], as: UTF16.self)
                mentions.append(Mention(handle: name.lowercased(), range: NSRange(location: i, length: end - i)))
            }
            i = max(j, i + 1)
        }
        return MentionParse(mentions: mentions)
    }

    /// The partial handle being typed at the end of `text` (for autocomplete),
    /// or nil when the caret isn't inside a mention.
    public static func activeQuery(in text: String) -> String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        if atIndex > text.startIndex {
            let before = text[text.index(before: atIndex)]
            if Handles.isHandleCharacter(before) { return nil }
        }
        let fragment = text[text.index(after: atIndex)...]
        guard fragment.allSatisfy(Handles.isHandleCharacter) else { return nil }
        return fragment.lowercased()
    }

    /// Replace the trailing partial mention with a completed `@handle `.
    public static func complete(_ text: String, with handle: String) -> String {
        guard activeQuery(in: text) != nil, let atIndex = text.lastIndex(of: "@") else {
            return text + "@\(handle) "
        }
        return String(text[..<atIndex]) + "@\(handle) "
    }
}
