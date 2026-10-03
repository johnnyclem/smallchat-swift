import Foundation
import SmallChatCore

// MARK: - Truth format v2: the line codec
//
// The contract is stenographer's spec/truth-format (README, JSON Schema and
// golden fixtures, copied into Tests/Fixtures/truth-format by
// Scripts/sync-truth-fixtures.sh). A truth file is UTF-8 JSONL, one
// writer's stream. Every v2 line carries `schemaVersion: 2`, `seq` (1, 2,
// 3, … with no gaps), `prevHash` (the previous line's `hash`; null on seq 1
// only) and `hash` (lowercase hex SHA-256 of the line's RFC 8785 JCS form
// without `hash`). Lines without `schemaVersion` are version 1
// (stenographer 0.x): no chain, a `status` field, still readable.
//
// `TruthFormat.decode` validates one line — the structure the schema
// describes, plus what JSON Schema can't express: the hash, the identity
// rules, the link rules and the agent quorum rules (`TruthQuorum`) — and
// throws `TruthLineError` when a reader must refuse it.
// `TruthFormat.checkChain` checks that decoded lines form one stream. Unknown fields and unknown values of status, kinds, link types,
// cause kinds and signal sources are kept, never refused and never coerced.
// The line `type` and the required fields are closed. The reference codec
// is stenographer's src/truth/wiki.ts.

/// The six line types of truth format v2. A version 1 line is a TB or UV.
public enum TruthLineType: String, Sendable, CaseIterable {
    case tb = "TB"
    case uv = "UV"
    case addendum = "ADDENDUM"
    case ruling = "RULING"
    case proposal = "PROPOSAL"
    case transition = "TRANSITION"
}

/// A line a reader must refuse.
public struct TruthLineError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// One line, read and validated.
public struct DecodedTruthLine: Sendable {
    /// 1 or 2.
    public let version: Int
    public let type: TruthLineType
    /// The parsed line, unknown fields included.
    public let object: [String: AnyCodableValue]
    /// The line exactly as read: what re-serialization writes back.
    public let text: String
    /// Version 2 only.
    public let seq: Int?
    public let prevHash: String?
    public let hash: String?

    public var id: String {
        if case .string(let id)? = object["id"] { return id }
        return ""
    }
}

/// The last line of a stream a reader has read.
public struct TruthStreamHead: Sendable, Equatable {
    public let seq: Int
    public let hash: String

    public init(seq: Int, hash: String) {
        self.seq = seq
        self.hash = hash
    }
}

public enum TruthFormat {
    public static let schemaVersion = 2

    /// The statuses this version knows, in lattice order (a reader merging
    /// several files takes the most advanced). Any other status, or none,
    /// is not current truth.
    public static let tbStatuses = TbStatus.known.map(\.rawValue)
    public static let uvStatuses = UvStatus.known.map(\.rawValue)

    /// Link types this version knows. A link of any other type is kept and not judged.
    public static let linkTypes = ["supersedes", "contests", "verifies", "refutes", "signs", "overrides", "strikes", "dismisses"]

    /// Links a TB or UV line may carry from itself, and into itself (its own history).
    static let outboundLinks: [TruthLineType: [String]] = [.tb: ["supersedes", "signs"], .uv: ["contests", "signs"]]
    static let inboundLinks: [TruthLineType: [String]] = [
        .tb: ["overrides", "contests", "supersedes", "strikes"],
        .uv: ["verifies", "refutes", "supersedes", "strikes"],
    ]

    /// Version 1 lines were validated like a live write: closed evidence and verifyBy kinds.
    static let v1EvidenceKinds = TruthEvidence.Kind.known.map(\.rawValue)
    static let v1VerifyKinds = TruthVerifyBy.Kind.known.map(\.rawValue)

    // MARK: Hash

    /// `sha256hex(JCS(line without "hash"))`: the hash a v2 line carries.
    /// Doesn't validate the line. Throws for a value with no canonical form.
    public static func hash(_ object: [String: AnyCodableValue]) throws -> String {
        var rest = object
        rest.removeValue(forKey: "hash")
        return sha256Hex(Array(try canonicalJSON(.dict(rest)).utf8))
    }

    /// The hash of a line's text (see `hash(_:)`).
    public static func hash(line text: String) throws -> String {
        guard case .dict(let object) = try parseJSON(text) else { throw TruthLineError("a line is a JSON object") }
        return try hash(object)
    }

    // MARK: Writing

    /// Chains line bodies into a stream as a writer does: each body (a JSON
    /// object text with the line's own fields, in order) gets
    /// `schemaVersion: 2` and `seq` in front, `prevHash` and `hash` at the
    /// end, continuing `head` (or starting at seq 1). It does not validate
    /// the bodies — `decode` does. Truth itself is stenographer's to write
    /// (one writer per wiki file); this package writes PROPOSAL lines only.
    public static func chain(_ bodies: [String], after head: TruthStreamHead? = nil) throws -> [String] {
        var seq = head?.seq ?? 0
        var prev = head?.hash
        return try bodies.map { body in
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { throw TruthLineError("a line body is a JSON object") }
            seq += 1
            let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            let chainFields = "\"prevHash\":" + (prev.map(jsonQuoted) ?? "null")
            let unhashed = "{\"schemaVersion\":\(schemaVersion),\"seq\":\(seq)," + (inner.isEmpty ? "" : inner + ",") + chainFields + "}"
            let hash = try hash(line: unhashed)
            prev = hash
            return String(unhashed.dropLast()) + ",\"hash\":\"\(hash)\"}"
        }
    }

    // MARK: Decoding

    /// Reads one line: validates it (v2, or v1 from stenographer 0.x) and,
    /// for v2, checks its hash. Throws `TruthLineError` when a reader must
    /// refuse it. Chain continuity across lines is `checkChain`'s.
    public static func decode(_ text: String) throws -> DecodedTruthLine {
        let parsed: AnyCodableValue
        do {
            parsed = try parseJSON(text)
        } catch {
            throw TruthLineError("not JSON: \(error)")
        }
        guard case .dict(let object) = parsed else { throw TruthLineError("a line is a JSON object") }
        switch object["schemaVersion"] {
        case nil:
            return try decodeV1(object, text)
        case let version? where number(version) == 1:
            return try decodeV1(object, text)
        case let version? where number(version) == 2:
            return try decodeV2(object, text)
        case let version?:
            throw TruthLineError("schemaVersion \(jsonText(version)) is not one this reader knows (1, 2) — refusing rather than guessing")
        }
    }

    private static func decodeV2(_ o: [String: AnyCodableValue], _ raw: String) throws -> DecodedTruthLine {
        for key in ["seq", "id", "type", "ts", "author", "prevHash", "hash"] where o[key] == nil {
            throw fail(key, "is required")
        }
        guard let seqValue = number(o["seq"]!), seqValue.rounded() == seqValue, seqValue >= 1, seqValue <= 9_007_199_254_740_991 else {
            throw fail("seq", "must be an integer of at least 1")
        }
        let seq = Int(seqValue)
        try requireId(o, "id")
        guard case .string(let typeName)? = o["type"], let type = TruthLineType(rawValue: typeName) else {
            throw fail("type", "\(jsonText(o["type"]!)) is not a truth line type (\(TruthLineType.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        guard case .string(let ts)? = o["ts"], isRFC3339DateTime(ts) else {
            if case .string(let ts)? = o["ts"], hasLeapSecond(ts) {
                throw fail("ts", "a leap second (:60) is not a time this codec reads")
            }
            throw fail("ts", "must be an RFC 3339 date-time naming a real time")
        }
        guard case .string(let author)? = o["author"], !author.isEmpty else { throw fail("author", "must be a non-empty string") }
        let prevHash: String?
        switch o["prevHash"]! {
        case .null: prevHash = nil
        case .string(let s) where isHex64(s): prevHash = s
        default: throw fail("prevHash", "a hash is 64 lowercase hex digits, or null")
        }
        guard case .string(let hash)? = o["hash"], isHex64(hash) else { throw fail("hash", "a hash is 64 lowercase hex digits") }
        if (seq == 1) != (prevHash == nil) {
            throw fail("prevHash", "is null on the first line of a stream (seq 1), and only there")
        }
        let links = try xSteno(o)

        switch type {
        case .tb:
            try requireText(o, "claim")
            try evidenceList(o, "evidence", v1: false)
            guard let signedBy = o["signedBy"] else { throw fail("signedBy", "is required (an identity, or null on a backfilled TB)") }
            if signedBy != .null { try identity(o, "signedBy") }
            try literals(o, version: 2)
            try status(o)
            // The backfill's second-class TBs are the one place 'migration' authors one, unsigned
            if !(identityKey(author) == truthMigrationAuthor && signedBy == .null) { try identity(o, "author") }
        case .uv:
            try requireText(o, "assertion")
            try requireText(o, "basis")
            try verifyBy(o, v1: false)
            guard let contests = o["contests"] else { throw fail("contests", "is required (the contested TB id, or null)") }
            if contests != .null { try requireId(o, "contests") }
            try status(o)
            try identity(o, "author")
        case .addendum:
            try evidenceList(o, "evidence", v1: false)
            try nullableString(o, "note", required: true)
            try identity(o, "author")
        case .ruling:
            try requireText(o, "kind")
            guard case .string(let opinion)? = o["opinion"], opinion.unicodeScalars.contains(where: { !isECMAScriptWhitespace($0) }) else {
                throw fail("opinion", "cannot be blank")
            }
            try requireId(o, "target")
            try identity(o, "author")
        case .proposal:
            try requireText(o, "kind")
            guard case .dict? = o["draft"] else { throw fail("draft", "must be an object") }
            try nullableString(o, "targetRef", required: true)
            guard case .dict(let signal)? = o["signal"] else { throw fail("signal", "must be an object") }
            try requireText(signal, "source", path: "signal.source")
            try nullableString(o, "agentSessionId")
            // Detectors file proposals
            try identity(o, "author", allowDetector: true)
        case .transition:
            try requireId(o, "target")
            try requireText(o, "status")
            guard case .dict(let cause)? = o["cause"] else { throw fail("cause", "is required: {kind, ref}") }
            try requireText(cause, "kind", path: "cause.kind")
            guard let ref = cause["ref"] else { throw fail("cause.ref", "is required (the causing entry id, or null)") }
            if ref != .null { try requireId(cause, "ref", path: "cause.ref") }
            // A transition's author is its cause's: a person or an agent, never 'migration' or a detector
            try identity(o, "author")
        }
        try checkLinks(o, type, links)
        // Agents settle only together: a quorum keeps rules 1–6, and appears only on a TB or an ADDENDUM
        let quorumIssues = TruthQuorum.issues(in: o)
        if !quorumIssues.isEmpty { throw fail("quorum", quorumIssues.joined(separator: "; ")) }

        let computed: String
        do {
            computed = try self.hash(o)
        } catch {
            throw fail("", "the line can't be canonicalized: \(error)")
        }
        guard computed == hash else {
            throw fail("", "hash mismatch: the line hashes to \(computed), not \(hash) — it was changed after it was written")
        }
        return DecodedTruthLine(version: 2, type: type, object: o, text: raw, seq: seq, prevHash: prevHash, hash: hash)
    }

    private static func decodeV1(_ o: [String: AnyCodableValue], _ raw: String) throws -> DecodedTruthLine {
        guard case .string(let typeName)? = o["type"], typeName == "TB" || typeName == "UV" else {
            throw fail("type", "a version 1 line is a TB or UV (got \(o["type"].map(jsonText) ?? "nothing"))")
        }
        let type: TruthLineType = typeName == "TB" ? .tb : .uv
        try requireId(o, "id")
        guard case .string(let ts)? = o["ts"], isTimestamp(ts) else { throw fail("ts", "must be a timestamp") }
        guard case .string(let author)? = o["author"] else { throw fail("author", "must be a string") }
        switch o["status"] {
        case nil, .string?: break
        default: throw fail("status", "must be a string")
        }
        switch o["x-steno"] {
        case nil, .dict?: break
        default: throw fail("x-steno", "must be an object")
        }

        if type == .tb {
            try requireText(o, "claim")
            try evidenceList(o, "evidence", v1: true)
            let signed: Bool
            switch o["signedBy"] {
            case nil, .null?: signed = false
            case .string(let s)?: signed = !s.isEmpty; try identity(o, "signedBy")
            default: try identity(o, "signedBy"); signed = true
            }
            try literals(o, version: 1)
            if !(identityKey(author) == truthMigrationAuthor && !signed) { try identity(o, "author") }
        } else {
            try identity(o, "author")
            try requireText(o, "assertion")
            try requireText(o, "basis")
            try verifyBy(o, v1: true)
            if let contests = o["contests"], contests != .null { try requireId(o, "contests") }
        }
        // 0.x wrote no quorum; an agent's settlement is a v2 line
        if o["quorum"] != nil { throw TruthLineError("a v1 line carries no quorum: agents settle claims together only on v2 lines") }
        return DecodedTruthLine(version: 1, type: type, object: o, text: raw, seq: nil, prevHash: nil, hash: nil)
    }

    // MARK: The chain

    /// Checks that decoded v2 lines form one stream: each line's seq follows
    /// the one before it and its prevHash is that line's hash. A stream may
    /// start part-way (an incremental export), but not skip, repeat,
    /// reorder or interleave two writers. Returns the index and error of
    /// each break; nil entries (refused lines) are skipped, and the line
    /// after one isn't compared with the line before it.
    public static func checkChain(_ lines: [DecodedTruthLine?]) -> [(index: Int, error: String)] {
        var breaks: [(index: Int, error: String)] = []
        var prev: (seq: Int, hash: String)?
        for (index, line) in lines.enumerated() {
            guard let line else {
                prev = nil  // a refused line: don't pile chain errors on top of its own
                continue
            }
            guard line.version == 2, let seq = line.seq, let hash = line.hash else { continue }
            if let p = prev, seq != p.seq + 1 {
                breaks.append((index, "chain broken: seq \(seq) follows \(p.seq) — a line is missing, repeated or out of order"))
            } else if let p = prev, line.prevHash != p.hash {
                breaks.append((index, "chain broken: prevHash \(line.prevHash ?? "null") is not the previous line's hash \(p.hash) — two writers' lines, or an edited one"))
            }
            prev = (seq, hash)
        }
        return breaks
    }

    // MARK: Literals

    /// Why a dead literal is invalid, or nil — stenographer's rule
    /// (`TombstonedLiteralSchema`, plus the codec's no-surrounding-whitespace
    /// rule on a v2 line). `dead` is a string, and so are `subject` and
    /// `current` when present (an explicit null is refused), each non-blank
    /// once trimmed; a v2 line states them exactly, with no surrounding
    /// whitespace. Without a `subject`, `dead` must be a distinctive
    /// identifier: at least 4 UTF-16 code units and an ASCII letter.
    public static func literalIssue(_ literal: AnyCodableValue, version: Int = 2) -> String? {
        guard case .dict(let l) = literal else { return "a literal must be an object" }
        for key in ["dead", "subject", "current"] {
            guard let value = l[key] else {
                if key == "dead" { return "a literal needs a dead value" }
                continue
            }
            guard case .string(let s) = value, !ecmaScriptTrim(s).isEmpty else {
                return key == "dead" ? "a literal needs a dead value" : "a literal's \(key) must be a non-blank string"
            }
            if version == 2, ecmaScriptTrim(s) != s {
                return "literal values cannot have surrounding whitespace (\(key))"
            }
        }
        guard l["subject"] == nil else { return nil }
        guard case .string(let dead)? = l["dead"], isDistinctiveIdentifier(ecmaScriptTrim(dead)) else {
            return "a literal without a subject must be a distinctive identifier (≥4 chars, contains a letter) — name the subject of bare values"
        }
        return nil
    }

    // MARK: Timestamps

    /// Whether `ts` is an RFC 3339 date-time (`T` and `Z` upper case) whose
    /// fields name a real time: no February 30, no 24:00, no offset past
    /// 23:59 and no leap second, as stenographer's codec reads it.
    public static func isRFC3339DateTime(_ ts: String) -> Bool {
        guard let f = rfc3339Fields(ts) else { return false }
        let leap = f.year % 4 == 0 && (f.year % 100 != 0 || f.year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(f.month), f.day >= 1, f.day <= days[f.month - 1] else { return false }
        guard f.hour <= 23, f.minute <= 59, f.second <= 59 else { return false }
        if let offset = f.offset, offset.hour > 23 || offset.minute > 59 { return false }
        return true
    }

    /// An RFC 3339 date-time as the agent quorum's rule 4 reads it:
    /// milliseconds since the epoch, any fractional digits past the third
    /// dropped (not rounded), the offset applied. Nil when `ts` isn't one
    /// (`isRFC3339DateTime`).
    static func epochMilliseconds(_ ts: String) -> Int64? {
        guard isRFC3339DateTime(ts), let f = rfc3339Fields(ts) else { return nil }
        // The fraction's first three digits, padded: ".5" is 500 ms, ".0009" is 0
        let b = Array(ts.utf8)
        var millisecond: Int64 = 0
        if b.count > 19, b[19] == UInt8(ascii: ".") {
            var scale: Int64 = 100
            var i = 20
            while i < b.count, scale > 0, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[i]) {
                millisecond += Int64(b[i] - UInt8(ascii: "0")) * scale
                scale /= 10
                i += 1
            }
        }
        // Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil)
        let y = Int64(f.month <= 2 ? f.year - 1 : f.year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * Int64((f.month + 9) % 12) + 2) / 5 + Int64(f.day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        var offsetMinutes: Int64 = 0
        if let offset = f.offset {
            offsetMinutes = Int64(offset.hour * 60 + offset.minute)
            if b.count > 6, b[b.count - 6] == UInt8(ascii: "-") { offsetMinutes = -offsetMinutes }
        }
        let seconds = days * 86_400 + Int64(f.hour * 3_600 + f.minute * 60 + f.second) - offsetMinutes * 60
        return seconds * 1_000 + millisecond
    }

    private static func hasLeapSecond(_ ts: String) -> Bool {
        rfc3339Fields(ts)?.second == 60
    }

    /// The fields of `YYYY-MM-DDTHH:MM:SS(.fraction)?(Z|±HH:MM)`, or nil when the text isn't shaped like that.
    /// The fields `rfc3339Fields` reads. A named type keeps the returns below explicit:
    /// Swift 6.4's type checker crashes on a ternary that returns this tuple or nil.
    private typealias RFC3339Fields = (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: (hour: Int, minute: Int)?)

    private static func rfc3339Fields(_ ts: String) -> RFC3339Fields? {
        let b = Array(ts.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= b.count else { return nil }
            var value = 0
            for byte in b[start..<(start + count)] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        func at(_ i: Int, _ c: Character) -> Bool { i < b.count && b[i] == c.asciiValue! }
        guard let year = digits(0, 4), at(4, "-"), let month = digits(5, 2), at(7, "-"), let day = digits(8, 2), at(10, "T"),
              let hour = digits(11, 2), at(13, ":"), let minute = digits(14, 2), at(16, ":"), let second = digits(17, 2)
        else { return nil }
        var i = 19
        if at(i, ".") {
            i += 1
            let start = i
            while i < b.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[i]) { i += 1 }
            guard i > start else { return nil }
        }
        if at(i, "Z") {
            guard i + 1 == b.count else { return nil }
            let fields: RFC3339Fields = (year, month, day, hour, minute, second, nil)
            return fields
        }
        guard at(i, "+") || at(i, "-"), let oh = digits(i + 1, 2), at(i + 3, ":"), let om = digits(i + 4, 2), i + 6 == b.count else {
            return nil
        }
        let fields: RFC3339Fields = (year, month, day, hour, minute, second, (hour: oh, minute: om))
        return fields
    }

    /// A version 1 `ts`: anything `Date.parse` reads in practice — an RFC 3339
    /// or ISO 8601 date-time, or a calendar date.
    private static func isTimestamp(_ ts: String) -> Bool {
        if rfc3339Fields(ts) != nil { return isRFC3339DateTime(ts) }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if withFraction.date(from: ts) != nil || ISO8601DateFormatter().date(from: ts) != nil { return true }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: ts) != nil
    }

    // MARK: Field checks

    private static func fail(_ path: String, _ message: String) -> TruthLineError {
        TruthLineError(path.isEmpty ? message : "\(path): \(message)")
    }

    static func number(_ value: AnyCodableValue) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    private static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$`
    static func isId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...256).contains(b.count) else { return false }
        func alnum(_ c: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c)
        }
        guard alnum(b[0]) else { return false }
        return b.dropFirst().allSatisfy { alnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "-") }
    }

    private static func requireId(_ o: [String: AnyCodableValue], _ key: String, path: String? = nil) throws {
        guard case .string(let s)? = o[key], isId(s) else {
            throw fail(path ?? key, "an id is 1–256 characters: letters, digits, . _ : - (starting with a letter or digit)")
        }
    }

    private static func requireText(_ o: [String: AnyCodableValue], _ key: String, path: String? = nil) throws {
        guard case .string(let s)? = o[key], !s.isEmpty else { throw fail(path ?? key, "must be a non-empty string") }
    }

    private static func optionalString(_ o: [String: AnyCodableValue], _ key: String, path: String) throws {
        switch o[key] {
        case nil, .string?: return
        default: throw fail(path, "must be a string")
        }
    }

    private static func nullableString(_ o: [String: AnyCodableValue], _ key: String, required: Bool = false) throws {
        switch o[key] {
        case nil: if required { throw fail(key, "is required (a string or null)") }
        case .null?, .string?: return
        default: throw fail(key, "must be a string or null")
        }
    }

    private static func identity(_ o: [String: AnyCodableValue], _ key: String, allowDetector: Bool = false) throws {
        guard case .string(let s)? = o[key] else { throw fail(key, "an identity is a string") }
        if let issue = identityIssue(s, allowDetector: allowDetector) { throw fail(key, issue) }
    }

    private static func evidenceList(_ o: [String: AnyCodableValue], _ key: String, v1: Bool) throws {
        guard case .array(let list)? = o[key], !list.isEmpty else { throw fail(key, "at least one piece of evidence is required") }
        for (i, item) in list.enumerated() {
            let path = "\(key).\(i)"
            guard case .dict(let e) = item else { throw fail(path, "must be an object") }
            try requireText(e, "kind", path: "\(path).kind")
            if v1, case .string(let kind)? = e["kind"], !v1EvidenceKinds.contains(kind) {
                throw fail("\(path).kind", "'\(kind)' is not an evidence kind a version 1 line could carry")
            }
            try requireText(e, "ref", path: "\(path).ref")
            try optionalString(e, "detail", path: "\(path).detail")
        }
    }

    private static func verifyBy(_ o: [String: AnyCodableValue], v1: Bool) throws {
        guard case .dict(let v)? = o["verifyBy"] else { throw fail("verifyBy", "must be an object") }
        try requireText(v, "kind", path: "verifyBy.kind")
        if v1, case .string(let kind)? = v["kind"], !v1VerifyKinds.contains(kind) {
            throw fail("verifyBy.kind", "'\(kind)' is not a verifyBy kind a version 1 line could carry")
        }
        try requireText(v, "value", path: "verifyBy.value")
        try optionalString(v, "detail", path: "verifyBy.detail")
    }

    private static func literals(_ o: [String: AnyCodableValue], version: Int) throws {
        guard let value = o["literals"] else { return }
        guard case .array(let list) = value, version == 1 || !list.isEmpty else {
            throw fail("literals", "omit literals rather than send none")
        }
        for (i, literal) in list.enumerated() {
            if let issue = literalIssue(literal, version: version) { throw fail("literals.\(i)", issue) }
        }
    }

    private static func status(_ o: [String: AnyCodableValue]) throws {
        guard let value = o["status"] else { return }
        guard case .string(let s) = value, !s.isEmpty else { throw fail("status", "must be a non-empty string") }
    }

    private struct Link: Equatable {
        let fromId: String
        let toId: String
        let type: String
    }

    private static func xSteno(_ o: [String: AnyCodableValue]) throws -> [Link]? {
        guard let value = o["x-steno"] else { return nil }
        guard case .dict(let x) = value else { throw fail("x-steno", "must be an object") }
        if x["origin"] != nil { try requireText(x, "origin", path: "x-steno.origin") }
        if let provenance = x["provenance"] {
            guard case .dict(let p) = provenance else { throw fail("x-steno.provenance", "must be an object") }
            try requireText(p, "kind", path: "x-steno.provenance.kind")
            try optionalString(p, "ref", path: "x-steno.provenance.ref")
            if let line = p["line"] {
                guard let n = number(line), n.rounded() == n else { throw fail("x-steno.provenance.line", "must be an integer") }
            }
        }
        for key in ["agentSessionId", "targetRef"] {
            switch x[key] {
            case nil, .null?, .string?: break
            default: throw fail("x-steno.\(key)", "must be a string or null")
            }
        }
        if let ledgerHash = x["ledgerHash"] {
            guard case .string(let s) = ledgerHash, isHex64(s) else { throw fail("x-steno.ledgerHash", "a hash is 64 lowercase hex digits") }
        }
        guard let linksValue = x["links"] else { return nil }
        guard case .array(let list) = linksValue else { throw fail("x-steno.links", "must be an array") }
        var links: [Link] = []
        for (i, item) in list.enumerated() {
            let path = "x-steno.links.\(i)"
            guard case .dict(let l) = item else { throw fail(path, "must be an object") }
            try requireId(l, "fromId", path: "\(path).fromId")
            try requireId(l, "toId", path: "\(path).toId")
            try requireText(l, "type", path: "\(path).type")
            guard case .string(let from)? = l["fromId"], case .string(let to)? = l["toId"], case .string(let type)? = l["type"] else {
                throw fail(path, "must be a link")
            }
            let link = Link(fromId: from, toId: to, type: type)
            if links.contains(link) { throw fail("x-steno.links", "a line lists each link once") }
            links.append(link)
        }
        return links
    }

    /// The link rules: a TB/UV line speaks only for itself, an ADDENDUM/RULING lists only the links it writes.
    private static func checkLinks(_ o: [String: AnyCodableValue], _ type: TruthLineType, _ links: [Link]?) throws {
        guard let links else { return }
        guard case .string(let me)? = o["id"] else { return }
        if type == .tb || type == .uv {
            for (i, l) in links.enumerated() where linkTypes.contains(l.type) {  // an unknown type: not ours to judge
                let own = (l.fromId == me && outboundLinks[type]!.contains(l.type))
                    || (l.toId == me && l.fromId != me && inboundLinks[type]!.contains(l.type))
                if !own { throw fail("x-steno.links.\(i)", "a \(type.rawValue) line cannot carry the link \(l.fromId) -\(l.type)-> \(l.toId)") }
            }
        }
        if type == .uv {
            var contests: String?
            if case .string(let c)? = o["contests"] { contests = c }
            let contestLinks = links.filter { $0.type == "contests" && $0.fromId == me }
            if let contests, !contestLinks.contains(where: { $0.toId == contests }) {
                throw fail("x-steno.links", "a UV that contests a TB lists its contests link in x-steno.links")
            }
            if contestLinks.contains(where: { $0.toId != contests }) {
                throw fail("x-steno.links", "a contests link points at the TB the contests field names")
            }
        }
        if type == .addendum || type == .ruling {
            for (i, l) in links.enumerated() where l.fromId != me {
                throw fail("x-steno.links.\(i)", "\(type == .addendum ? "an" : "a") \(type.rawValue) line lists only the links it writes")
            }
        }
    }
}

// MARK: - JSON text helpers

/// A string as `JSON.stringify` writes it.
func jsonQuoted(_ s: String) -> String {
    // canonicalJSON throws only for non-finite numbers
    try! canonicalJSON(.string(s))
}

/// A value's JSON text (canonical form), for messages and hand-built lines.
func jsonText(_ value: AnyCodableValue) -> String {
    (try? canonicalJSON(value)) ?? "?"
}

/// A JSON object with members in the given order (values already JSON text).
func jsonObject(_ members: [(String, String)]) -> String {
    "{" + members.map { jsonQuoted($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
}
