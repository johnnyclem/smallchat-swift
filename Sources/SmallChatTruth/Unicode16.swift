// MARK: - Unicode 16.0 normalization and lowercasing
//
// Identity keys (truth format v2, "Identities") are NFKC, default-ignorable
// code points removed, trimmed, lowercased, and a signer registry stores a
// name as NFC. Stenographer and short-hand compute these with their
// runtime's ICU: on Node 22, ICU 77.1, which implements Unicode 16.0. The
// platform's own data can't stand in for it: Foundation's normalization on
// Linux is Unicode 15.x (it leaves Unicode 16.0's OUTLINED LATIN CAPITAL
// LETTERs alone, where NFKC folds them to A..Z), the Swift runtime's
// character properties follow its version (Swift 6.4's are Unicode 17.0,
// where U+0295 ʕ is no longer a cased letter, and U+A7CE gained a lowercase
// form), and on Apple platforms the runtime is the OS's. So this reads the
// Unicode Character Database 16.0.0 tables in UnicodeTables16.swift, written
// by Scripts/generate-unicode-tables.mjs, and nothing else: a key is the same
// on every platform, and the same as stenographer's on Node 22, code point
// for code point. TruthUnicodeTests checks the tables against Node 22's ICU.
// The truth format doesn't name a Unicode version: on Node 24 (ICU 78,
// Unicode 17.0) stenographer keys some identities differently.

enum Unicode16 {

    // MARK: Normalization

    /// NFKC: the compatibility decomposition, in canonical order, composed.
    static func nfkc(_ scalars: some Sequence<Unicode.Scalar>) -> [Unicode.Scalar] {
        compose(decompose(scalars, compatibility: true))
    }

    /// NFC: the canonical decomposition, in canonical order, composed.
    static func nfc(_ s: String) -> String {
        string(compose(decompose(s.unicodeScalars, compatibility: false)))
    }

    /// NFD: the canonical decomposition, in canonical order.
    static func nfd(_ s: String) -> String {
        string(decompose(s.unicodeScalars, compatibility: false))
    }

    /// The canonical combining class of `scalar` (0 for a starter and for a code point Unicode 16.0 doesn't assign).
    static func combiningClass(_ scalar: Unicode.Scalar) -> UInt8 {
        combiningClasses[scalar.value] ?? 0
    }

    /// The full decomposition of every scalar, Hangul syllables by algorithm, then put in canonical order.
    static func decompose(_ scalars: some Sequence<Unicode.Scalar>, compatibility: Bool) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for scalar in scalars {
            let v = scalar.value
            if v >= Hangul.sBase, v < Hangul.sBase + Hangul.sCount {
                let s = v - Hangul.sBase
                out.append(Unicode.Scalar(Hangul.lBase + s / Hangul.nCount)!)
                out.append(Unicode.Scalar(Hangul.vBase + (s % Hangul.nCount) / Hangul.tCount)!)
                if s % Hangul.tCount != 0 { out.append(Unicode.Scalar(Hangul.tBase + s % Hangul.tCount)!) }
            } else if let mapped = (compatibility ? compatibilityDecompositions[v] : nil) ?? canonicalDecompositions[v] {
                out.append(contentsOf: mapped)
            } else {
                out.append(scalar)
            }
        }
        // Canonical ordering: each run of non-starters, stably sorted by class
        var i = 0
        while i < out.count {
            guard combiningClass(out[i]) != 0 else {
                i += 1
                continue
            }
            var end = i
            while end < out.count, combiningClass(out[end]) != 0 { end += 1 }
            if end - i > 1 {
                for j in (i + 1)..<end {
                    let scalar = out[j]
                    let cc = combiningClass(scalar)
                    var k = j
                    while k > i, combiningClass(out[k - 1]) > cc {
                        out[k] = out[k - 1]
                        k -= 1
                    }
                    out[k] = scalar
                }
            }
            i = end
        }
        return out
    }

    /// Canonical composition of a decomposed string in canonical order (Unicode Standard, section 3.11).
    static func compose(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let first = scalars.first else { return [] }
        var out = [first]
        var starter = 0
        // The class of the last scalar kept after the starter: 0 when none is (the next one is
        // adjacent), 256 when the string doesn't start with a starter (nothing composes with it)
        var lastClass: Int = combiningClass(first) == 0 ? 0 : 256
        for scalar in scalars.dropFirst() {
            let cc = Int(combiningClass(scalar))
            if lastClass < cc || lastClass == 0, let composite = composite(out[starter], scalar) {
                out[starter] = composite
                continue
            }
            if cc == 0 { starter = out.count }
            lastClass = cc
            out.append(scalar)
        }
        return out
    }

    /// The primary composite of `first` and `second`, Hangul syllables by algorithm, or nil.
    private static func composite(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> Unicode.Scalar? {
        let (a, b) = (first.value, second.value)
        if a >= Hangul.lBase, a < Hangul.lBase + Hangul.lCount, b >= Hangul.vBase, b < Hangul.vBase + Hangul.vCount {
            return Unicode.Scalar(Hangul.sBase + ((a - Hangul.lBase) * Hangul.vCount + (b - Hangul.vBase)) * Hangul.tCount)
        }
        if a >= Hangul.sBase, a < Hangul.sBase + Hangul.sCount, (a - Hangul.sBase) % Hangul.tCount == 0,
           b > Hangul.tBase, b < Hangul.tBase + Hangul.tCount {
            return Unicode.Scalar(a + (b - Hangul.tBase))
        }
        return compositions[UInt64(a) << 21 | UInt64(b)].flatMap(Unicode.Scalar.init)
    }

    private enum Hangul {
        static let sBase: UInt32 = 0xAC00, lBase: UInt32 = 0x1100, vBase: UInt32 = 0x1161, tBase: UInt32 = 0x11A7
        static let lCount: UInt32 = 19, vCount: UInt32 = 21, tCount: UInt32 = 28
        static let nCount = vCount * tCount, sCount = lCount * nCount
    }

    // MARK: Properties

    static func isDefaultIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        contains(defaultIgnorables, scalar.value)
    }

    static func isCased(_ scalar: Unicode.Scalar) -> Bool {
        contains(casedRanges, scalar.value)
    }

    static func isCaseIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        contains(caseIgnorableRanges, scalar.value)
    }

    // MARK: Lowercasing

    /// `s.toLowerCase()` as ECMAScript lowercases (ICU's root locale): each
    /// scalar's full lowercase mapping, and Final_Sigma, the one context
    /// Unicode's default mapping has. A Σ (U+03A3) after a cased letter, and
    /// before none, case-ignorable scalars skipped both ways, is ς (U+03C2);
    /// any other is σ (U+03C3). A scalar that is both cased and case-ignorable
    /// is skipped, as ICU skips it.
    static func lowercased(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return s.lowercased() }
        let scalars = Array(s.unicodeScalars)
        /// Whether the first scalar at `indices` that isn't case-ignorable is cased.
        func reachesCased(_ indices: some Sequence<Int>) -> Bool {
            for i in indices where !isCaseIgnorable(scalars[i]) {
                return isCased(scalars[i])
            }
            return false
        }
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}" {
                let final = reachesCased(stride(from: i - 1, through: 0, by: -1)) && !reachesCased(i + 1 ..< scalars.count)
                out.append(final ? "\u{03C2}" : "\u{03C3}")
            } else if let mapped = lowercaseMappings[scalar.value] {
                out.append(contentsOf: mapped)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: Reading the tables

    static let canonicalDecompositions = mappings(canonicalDecompositionTable)
    static let compatibilityDecompositions = mappings(compatibilityDecompositionTable)
    static let lowercaseMappings = mappings(lowercaseTable)
    static let defaultIgnorables = ranges(defaultIgnorableTable)
    static let casedRanges = ranges(casedTable)
    static let caseIgnorableRanges = ranges(caseIgnorableTable)

    static let combiningClasses: [UInt32: UInt8] = {
        var classes: [UInt32: UInt8] = [:]
        for entry in entries(combiningClassTable) {
            let parts = entry.split(separator: ":")
            for v in range(parts[0]) { classes[v] = UInt8(parts[1])! }
        }
        return classes
    }()

    /// By `first << 21 | second`.
    static let compositions: [UInt64: UInt32] = {
        var pairs: [UInt64: UInt32] = [:]
        for entry in entries(compositionTable) {
            let parts = entry.split(separator: ":")
            let pair = parts[0].split(separator: ",").map(hex)
            pairs[UInt64(pair[0]) << 21 | UInt64(pair[1])] = hex(parts[1])
        }
        return pairs
    }()

    private static func entries(_ table: String) -> [Substring] {
        table.split(whereSeparator: { $0 == " " || $0 == "\n" })
    }

    private static func hex(_ text: Substring) -> UInt32 {
        UInt32(text, radix: 16)!
    }

    /// `A` or `A-B`.
    private static func range(_ text: Substring) -> ClosedRange<UInt32> {
        let bounds = text.split(separator: "-")
        return hex(bounds[0])...hex(bounds[bounds.count - 1])
    }

    /// `cp:t1,t2,…`, `A-B:T` (A+i to T+i) and `A-B/2:T` (A+2i to T+2i).
    private static func mappings(_ table: String) -> [UInt32: [Unicode.Scalar]] {
        var mapped: [UInt32: [Unicode.Scalar]] = [:]
        for entry in entries(table) {
            let parts = entry.split(separator: ":")
            let targets = parts[1].split(separator: ",").map { Unicode.Scalar(hex($0))! }
            let source = parts[0].split(separator: "/")
            let step = source.count == 2 ? UInt32(source[1])! : 1
            let codePoints = range(source[0])
            if codePoints.count == 1 {
                mapped[codePoints.lowerBound] = targets
                continue
            }
            for v in stride(from: codePoints.lowerBound, through: codePoints.upperBound, by: Int(step)) {
                mapped[v] = [Unicode.Scalar(targets[0].value + (v - codePoints.lowerBound))!]
            }
        }
        return mapped
    }

    private static func ranges(_ table: String) -> [ClosedRange<UInt32>] {
        entries(table).map(range)
    }

    /// Whether sorted, disjoint `ranges` hold `v`.
    private static func contains(_ ranges: [ClosedRange<UInt32>], _ v: UInt32) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < v {
                low = mid + 1
            } else if ranges[mid].lowerBound > v {
                high = mid
            } else {
                return true
            }
        }
        return false
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
