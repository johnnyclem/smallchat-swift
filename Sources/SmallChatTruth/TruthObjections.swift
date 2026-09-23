import Foundation

// MARK: - Real-time objections (§12)
//
// Port of stenographer's assertion-contradicts-TB detector. Precision over
// recall: only tombstoned *literals* declared on an active or contested TB
// are matched — not paraphrases. A line that also mentions the replacement
// value is discussing the change, not asserting the dead value, and is
// skipped. Objections are operational state, never truth: whoever is in
// the session decides what to do with them.

/// One objection: what was asserted, which TB it contradicts, and the line.
public struct TruthObjection: Sendable, Equatable {
    public let tombstone: TruthTbEntry
    public let literal: TruthTombstonedLiteral
    /// The transcript line objected to (trimmed, capped at 500 chars).
    public let transcriptLine: String

    /// Human-readable objection text, citing the replacement when known.
    public var summary: String {
        let subject = literal.subject.map { "\($0) = " } ?? ""
        let replacement = literal.current.map { " — current value is \($0)" } ?? ""
        return "Objection: asserts \(subject)\(literal.dead), tombstoned by \(tombstone.id)\(replacement). \(tombstone.claim)"
    }
}

public enum TruthObjections {
    /// How far after a subject a dead value may appear (`LOG_BUDGET = 30`).
    static let afterSubjectWindow = 40
    /// How far before a subject (`30 as the log budget`).
    static let beforeSubjectWindow = 20
    static let maxLineLength = 500

    /// Lines of `text` that assert a tombstoned literal.
    public static func findLiteralHits(in text: String, literal: TruthTombstonedLiteral) -> [String] {
        guard let dead = valueRegex(literal.dead) else { return [] }
        let current = literal.current.flatMap(valueRegex)
        let subject = literal.subject.flatMap(subjectRegex)

        var hits: [String] = []
        for line in text.components(separatedBy: "\n") {
            let deadSpans = spans(dead, in: line)
            if deadSpans.isEmpty { continue }
            if let current, !spans(current, in: line).isEmpty { continue }

            if let subject {
                let near = spans(subject, in: line).contains { s in
                    deadSpans.contains { d in
                        (d.lowerBound >= s.upperBound && d.lowerBound - s.upperBound <= afterSubjectWindow)
                            || (d.upperBound <= s.lowerBound && s.lowerBound - d.upperBound <= beforeSubjectWindow)
                    }
                }
                if !near { continue }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            hits.append(String(trimmed.prefix(maxLineLength)))
        }
        return hits
    }

    /// Check a message against every matchable tombstone. Overridden TBs are
    /// history and never object; contested ones still do (the dispute is
    /// carried, not resolved).
    public static func check(_ text: String, against tombstones: [TruthTbEntry]) -> [TruthObjection] {
        var objections: [TruthObjection] = []
        for tb in tombstones where tb.status != .overridden {
            for literal in tb.literals {
                for line in findLiteralHits(in: text, literal: literal) {
                    objections.append(TruthObjection(tombstone: tb, literal: literal, transcriptLine: line))
                }
            }
        }
        return objections
    }

    // MARK: Patterns

    /// Exact, case-sensitive token: "30" doesn't match "300" or "30.5".
    static func valueRegex(_ value: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: value)
        return try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])\(escaped)(?![A-Za-z0-9_]|\\.\\d)")
    }

    /// Subject pattern tolerant of naming drift: "logBudget", "LOG_BUDGET",
    /// "log-budget", and "log budget" all match; "maxLogBudget" doesn't.
    static func subjectRegex(_ subject: String) -> NSRegularExpression? {
        let words = splitWords(subject).map(NSRegularExpression.escapedPattern(for:))
        guard !words.isEmpty else { return nil }
        let body = words.joined(separator: "[\\s_\\-.]*")
        return try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(body)(?![A-Za-z0-9_])",
            options: [.caseInsensitive]
        )
    }

    /// Split on separators and lower→upper camel-case boundaries.
    static func splitWords(_ subject: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in subject {
            if ch == " " || ch == "_" || ch == "-" || ch == "." || ch.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func spans(_ regex: NSRegularExpression, in line: String) -> [Range<Int>] {
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map {
            $0.range.location ..< ($0.range.location + $0.range.length)
        }
    }
}
