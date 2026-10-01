import Foundation

// MARK: - Escaping untrusted text (truth format v2, frozen markers)
//
// The suite renders truth into a model's context with frozen markers:
// `[TB]`, `[TB ⚠ CONTESTED]` and `[UV — UNVERIFIED]`. Text that comes from
// messages, tool output or ledger fields is untrusted, so it can never
// produce one: a `\` goes in front of any frozen marker (`[TB…`, `[UV…`,
// anywhere), any section marker at a line start, and a reproduced
// `## Asserted Truth` heading. A ledger claim containing "\n- [TB] …"
// renders as "\[TB] …", never as ledger truth.
//
// Markers are matched as a model reads them, not byte for byte: a bracket
// whose NFKC form is `[` (`［`, `﹇`), letters in any case, width or script
// look-alike (`[ｔB]`, Cyrillic `[ТВ]`), with invisible code points or
// combining marks anywhere in them, and a line start behind indentation,
// quote or list marks, non-breaking spaces or invisible code points. Inside
// fenced code blocks only the frozen markers are escaped. Everything else is
// left byte for byte, and escaped text passes through unchanged. This is a
// port of @shorthand/core's `escapeUntrusted` (compaction/frame.ts), so the
// Swift and TypeScript renderers escape the same text the same way.

public enum TruthEscaping {

    /// Neutralize marker syntax in untrusted text. `singleLine` collapses
    /// line breaks (and the spaces around them) to one space, for one-line
    /// items such as ledger fields.
    public static func escapeUntrusted(_ text: String, singleLine: Bool = false) -> String {
        let scalars = Array(text.unicodeScalars)
        if singleLine {
            return escapeMarkers(collapseLineBreaks(scalars), frozenOnly: false)
        }
        // Fenced code blocks (```…```): inside them only the frozen markers are escaped
        var out = String.UnicodeScalarView()
        var last = 0
        var i = 0
        while i < scalars.count {
            if isFence(scalars, i), let close = fenceEnd(scalars, from: i + 3) {
                out.append(contentsOf: escapeMarkers(Array(scalars[last..<i]), frozenOnly: false).unicodeScalars)
                out.append(contentsOf: escapeMarkers(Array(scalars[i..<close]), frozenOnly: true).unicodeScalars)
                last = close
                i = close
            } else {
                i += 1
            }
        }
        out.append(contentsOf: escapeMarkers(Array(scalars[last...]), frozenOnly: false).unicodeScalars)
        return String(out)
    }

    // MARK: Fences and line breaks

    private static func isFence(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        i + 2 < s.count && s[i] == "`" && s[i + 1] == "`" && s[i + 2] == "`"
    }

    /// The index just past the closing ``` of a fence whose body starts at `from`, or nil when it never closes.
    private static func fenceEnd(_ s: [Unicode.Scalar], from: Int) -> Int? {
        var j = from
        while j < s.count {
            if isFence(s, j) { return j + 3 }
            j += 1
        }
        return nil
    }

    private static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}"
    }

    /// `/[ \t]*(?:\r\n|[\r\n\u2028\u2029])+[ \t]*/g` → one space, matched
    /// left to right as the regular expression is.
    private static func collapseLineBreaks(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count, isBlank(s[j]) { j += 1 }
            guard j < s.count, isLineBreak(s[j]) else {
                out.append(s[i])
                i += 1
                continue
            }
            while j < s.count, isLineBreak(s[j]) { j += 1 }
            while j < s.count, isBlank(s[j]) { j += 1 }
            out.append(" ")
            i = j
        }
        return out
    }

    // MARK: Markers

    /// Code points whose NFKC form is `[`: `[`, vertical `﹇`, full-width `［`.
    private static let openBrackets: Set<Unicode.Scalar> = ["[", "\u{FE47}", "\u{FF3B}"]
    /// Code points whose NFKC form is `#`: `#`, small `﹟`, full-width `＃`.
    private static let hashes: Set<Unicode.Scalar> = ["#", "\u{FE5F}", "\u{FF03}"]

    /// Letters of other scripts a model reads as Latin T, B, U or V (from Unicode's confusables).
    private static let homoglyphs: [Unicode.Scalar: String] = [
        // T: Cyrillic Те, Greek tau, Cherokee, Lisu, small capital
        "\u{0422}": "t", "\u{0442}": "t", "\u{03A4}": "t", "\u{03C4}": "t", "\u{13A2}": "t", "\u{A4D4}": "t", "\u{1D1B}": "t",
        // B: Cyrillic Ve and soft sign, Greek beta, Cherokee, Lisu, small capital
        "\u{0412}": "b", "\u{0432}": "b", "\u{042C}": "b", "\u{044C}": "b", "\u{0392}": "b", "\u{03B2}": "b", "\u{13F4}": "b", "\u{A4D0}": "b", "\u{0299}": "b",
        // U: Armenian Seh, Greek upsilon, Lisu, small capital
        "\u{054D}": "u", "\u{057D}": "u", "\u{03C5}": "u", "\u{A4F4}": "u", "\u{1D1C}": "u",
        // V: Cyrillic izhitsa, Greek nu, Cherokee, Lisu, small capital
        "\u{0474}": "v", "\u{0475}": "v", "\u{03BD}": "v", "\u{13D9}": "v", "\u{A4E6}": "v", "\u{1D20}": "v",
    ]

    /// Frozen truth markers (`[TB…`, `[UV…`), escaped anywhere. `[TBD]` is a word, not a marker.
    private static let frozenWords = ["tb", "uv"]
    /// Section markers, escaped when untrusted text puts them at a line start.
    private static let sectionWords = ["truth", "correction", "invariant", "memory", "code", "entity", "edge", "summary", "history", "recent"]
    /// The truth-section heading (after its `#`s), escaped when untrusted text reproduces it.
    private static let headingWords = ["asserted truth"]
    /// Folded characters a check needs: a frozen marker and its next character, the longest section marker or heading and its.
    private static let frozenAhead = 3
    private static let lineAhead = 15

    private static func isMark(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isLetterOrNumber(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// What may come before a section marker or heading on its line: indentation, quote and list marks, invisible code points.
    private static func isLinePrefix(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == ">" || c == "*" || c == "+" || c == "-"
            || c.properties.generalCategory == .spaceSeparator || c.properties.isDefaultIgnorableCodePoint
    }

    private static func fold(_ c: Unicode.Scalar) -> String {
        if c.isASCII { return String(c).lowercased() }
        if let mapped = homoglyphs[c] { return mapped }
        let decomposed = String(c).decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !isMark($0) }
        let plain = String(String.UnicodeScalarView(decomposed)).precomposedStringWithCompatibilityMapping.lowercased()
        if plain.utf16.count == 1, let only = plain.unicodeScalars.first { return homoglyphs[only] ?? plain }
        return plain
    }

    /// The text from `start`, folded, up to `max` UTF-16 units: leading
    /// whitespace and every default-ignorable code point and mark are
    /// dropped, and inner whitespace runs read as one space.
    private static func foldAhead(_ s: [Unicode.Scalar], _ start: Int, _ max: Int) -> String {
        var out = ""
        var i = start
        while i < s.count, out.utf16.count < max {
            let c = s[i]
            i += 1
            // ASCII punctuation and digits never start a marker: the common case (`[1,`, `[{`, `["`) ends here
            if out.isEmpty, c.isASCII, !c.properties.isAlphabetic, !isECMAScriptWhitespace(c) { return String(c) }
            if isECMAScriptWhitespace(c) {
                if !out.isEmpty, !out.hasSuffix(" ") { out += " " }
            } else if !c.properties.isDefaultIgnorableCodePoint {
                out += fold(c)
            }
        }
        return out
    }

    /// `^(?:w1|w2|…)(?![\p{L}\p{N}_])` on folded text.
    private static func startsWithWord(_ text: String, _ words: [String]) -> Bool {
        for word in words where text.hasPrefix(word) {
            let rest = text.unicodeScalars.dropFirst(word.unicodeScalars.count)
            guard let next = rest.first else { return true }
            if !(isLetterOrNumber(next) || next == "_") { return true }
        }
        return false
    }

    /// After a run of 1–6 `#`s at `start` (and spaces), does the line reproduce the truth heading?
    private static func isTruthHeading(_ s: [Unicode.Scalar], _ start: Int) -> Bool {
        var i = start
        while i < s.count, hashes.contains(s[i]), i - start <= 6 { i += 1 }
        return i - start <= 6 && startsWithWord(foldAhead(s, i, lineAhead), headingWords)
    }

    /// Put a `\` in front of every frozen truth marker and, unless
    /// `frozenOnly`, every section marker or truth heading at a line start.
    /// One pass; a bracket or `#` already preceded by `\` is left alone.
    private static func escapeMarkers(_ s: [Unicode.Scalar], frozenOnly: Bool) -> String {
        var out = String.UnicodeScalarView()
        var lineStart = true  // only line-prefix characters since the last line break
        var prev: Unicode.Scalar?
        for (i, c) in s.enumerated() {
            if prev != "\\" {
                var marker = false
                if openBrackets.contains(c) {
                    let atLineStart = !frozenOnly && lineStart
                    let ahead = foldAhead(s, i + 1, atLineStart ? lineAhead : frozenAhead)
                    marker = startsWithWord(ahead, frozenWords) || (atLineStart && startsWithWord(ahead, sectionWords))
                } else if !frozenOnly, lineStart, hashes.contains(c) {
                    marker = isTruthHeading(s, i)
                }
                if marker { out.append("\\") }
            }
            out.append(c)
            if isLineBreak(c) {
                lineStart = true
            } else if lineStart, !isLinePrefix(c) {
                lineStart = false
            }
            prev = c
        }
        return String(out)
    }
}
