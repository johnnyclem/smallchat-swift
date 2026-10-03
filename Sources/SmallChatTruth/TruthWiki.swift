import Foundation
import SmallChatCore

// MARK: - Reading truth streams
//
// Reads stenographer's truth format v2: one writer's hash-chained JSONL
// stream of TB and UV entry lines, the ADDENDUM and RULING lines that cause
// status changes, and a TRANSITION line for every change. Version 1 lines
// (stenographer 0.x: no chain, a `status` field, later lines for an id
// superseding earlier ones) are still read.
//
// - Status is a fold. An entry's current status is the status of the
//   highest-seq TRANSITION that targets it, else the entry line's own —
//   among the TRANSITIONs a reader honours. Overridden and struck TBs, and
//   verified, refuted and struck UVs, are final: a later TRANSITION can only
//   move them up the lattice. With a signer registry, a TRANSITION by
//   someone it doesn't list is not honoured either (both are `held`). A
//   TRANSITION's `cause.ref` must name an earlier line of the stream.
// - Fail closed. A missing or unknown status means not current truth; the
//   line is kept as history and written back verbatim. A v2 stream with any
//   refused line (bad hash, identity, structure) or a broken chain is
//   refused whole: a dropped TRANSITION must never revive a struck TB.
// - Admission. An unsigned TB is never truth on its own; a v1 TB has no
//   hash and is unverifiable (unless the host opts in); with a signer
//   registry, unlisted authors and signers are unverifiable; two lines
//   giving one id different content (compared as JCS bytes, unknown fields
//   included, the chain fields aside) are a conflict. Agents settle claims
//   only together: a TB an agent signs is truth only with a quorum (the
//   codec checked its rules) whose members are all agents
//   (agent-without-quorum), and never when it cites an evidence kind this
//   version doesn't know, on its line or in its quorum: the rules don't
//   refuse a line over one, so nothing shows two settling angles
//   (unknown-value, weighed first). Status changes come from TRANSITIONs:
//   like a person's acts, an agent quorum's are the writer's to check (an
//   ADDENDUM is a cause, which a reader never applies by itself).
// - Never rewrite. Unknown fields and values are kept, never coerced, and a
//   parsed entry serializes back to the exact line it was read from.
// - Several files (one per writer) fold one by one, then each entry takes
//   the most advanced status on the lattice TB
//   `active < contested < overridden < struck`, UV
//   `open < verified < refuted < struck`.

/// How a reader admits entries.
public struct TruthReadOptions: Sendable {
    /// Whose entries count (stenographer's `signers.json`). With one, a TB
    /// is truth only when its author and signer are listed as a person or
    /// an agent, a UV only when its author is, and a TRANSITION by someone
    /// it doesn't list is held; who is an agent is its `agent` role. Without
    /// one, any identity that passes the identity rules is accepted, and an
    /// agent is an identity whose key starts with `agent:`.
    public var signers: TruthSignerRegistry?
    /// Take version 1 TBs as truth. Off by default: a v1 line carries no
    /// hash, so nothing shows it is the line stenographer wrote
    /// (stenographer itself files them for a person to sign).
    public var admitV1Tbs: Bool

    public init(signers: TruthSignerRegistry? = nil, admitV1Tbs: Bool = false) {
        self.signers = signers
        self.admitV1Tbs = admitV1Tbs
    }
}

/// A refused line, a chain break, or a refused input (line 0).
public struct TruthReadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 1-based line number (blank lines count); 0 for the input as a whole.
    public let line: Int
    public let error: String
    public let id: String?
    public let file: String?

    public var description: String {
        let place = [file, line > 0 ? "line \(line)" : nil].compactMap { $0 }.joined(separator: " ")
        let what = id.map { " (\($0))" } ?? ""
        return place.isEmpty ? error + what : "\(place)\(what): \(error)"
    }
}

/// One line of the input, as read.
public struct TruthLineRecord: Sendable, Equatable {
    public let line: Int
    /// The line exactly as read.
    public let text: String
    public let version: Int
    public let type: TruthLineType
    public let id: String
    public let seq: Int?
    public let hash: String?
    public let file: String?
}

/// An id that two lines, or two files, give different content.
public struct TruthConflict: Sendable, Equatable {
    public let id: String
    public let files: [String]
}

/// One row of the fold as the spec's fixtures state it (`*.expected.json`).
public struct TruthStatusRow: Sendable, Equatable {
    public let type: String
    public let status: String?
    public let current: Bool
}

public enum TruthWiki {

    public struct ParseResult: Sendable {
        /// TB and UV entries in order of first appearance (a v1 re-emission
        /// moves an entry last), each with its folded status. Empty when the
        /// input was refused.
        public let entries: [TruthLedgerEntry]
        /// Refused lines and chain breaks. With a v2 stream, any of them refuses it.
        public let errors: [TruthReadError]
        /// True when the input was refused: nothing it says is truth.
        public let refused: Bool
        /// Every TRANSITION read, in order, including ones whose target isn't in the input.
        public let transitions: [TruthTransition]
        /// TRANSITIONs read but not applied, with the reason.
        public let held: [TruthHeldTransition]
        /// Every line read, verbatim. Empty when refused.
        public let lines: [TruthLineRecord]
        /// The last v2 line read (nil for a merge of several files).
        public let head: TruthStreamHead?
        /// Ids that lines or files give different content. Those entries are not truth.
        public let conflicts: [TruthConflict]

        static func refused(_ errors: [TruthReadError]) -> ParseResult {
            ParseResult(entries: [], errors: errors, refused: true, transitions: [], held: [], lines: [], head: nil, conflicts: [])
        }
    }

    // MARK: Parsing

    /// Parse one truth stream (JSONL text). Blank lines are skipped and
    /// counted in line numbers.
    public static func parse(_ jsonl: String, options: TruthReadOptions = TruthReadOptions()) -> ParseResult {
        parse(lines: jsonl.components(separatedBy: "\n"), options: options)
    }

    /// Parse one truth stream, given as lines. See the module comment for
    /// the fold, fail-closed and admission rules; `refused` says the input
    /// was refused as a whole.
    public static func parse(lines: [String], options: TruthReadOptions = TruthReadOptions()) -> ParseResult {
        let read = readFile(lines, options: options, file: nil)
        if read.refused { return .refused(read.errors) }
        var entries: [TruthLedgerEntry] = []
        for id in read.order {
            var entry = read.entries[id]!
            admit(&entry, conflict: read.conflicts[id], verifiable: entry.source?.version == 2, options: options)
            entries.append(entry)
        }
        return ParseResult(
            entries: entries,
            errors: read.errors,
            refused: false,
            transitions: read.transitions,
            held: read.held,
            lines: read.lines,
            head: read.head,
            conflicts: read.order.filter { read.conflicts[$0] != nil }.map { TruthConflict(id: $0, files: []) }
        )
    }

    /// Read several truth streams — one per writer, e.g. `wiki/<handle>.jsonl`
    /// — fold each on its own, then give each entry the most advanced status
    /// any of them reached. An id the files give different content is a
    /// conflict, not truth. If any file is refused, the merge is refused: a
    /// stream that can't be read might hold the strike that matters.
    public static func parseFiles(_ files: [(name: String, text: String)], options: TruthReadOptions = TruthReadOptions()) -> ParseResult {
        let reads = files.map { (name: $0.name, read: readFile($0.text.components(separatedBy: "\n"), options: options, file: $0.name)) }
        let errors = reads.flatMap(\.read.errors)
        if reads.contains(where: \.read.refused) { return .refused(errors) }

        var order: [String] = []
        var copies: [String: [(file: String, entry: TruthLedgerEntry, conflict: String?, key: String)]] = [:]
        for (name, read) in reads {
            for id in read.order {
                if copies[id] == nil { order.append(id) }
                copies[id, default: []].append((name, read.entries[id]!, read.conflicts[id], read.bodyKeys[id] ?? ""))
            }
        }

        var entries: [TruthLedgerEntry] = []
        var conflicts: [TruthConflict] = []
        for id in order {
            let list = copies[id]!
            var winner = list[0]
            for copy in list.dropFirst() {
                let r = latticeRank(copy.entry)
                let w = latticeRank(winner.entry)
                if r > w || (r == w && r == 5 && (copy.entry.statusValue ?? "").utf16.lexicographicallyPrecedes((winner.entry.statusValue ?? "").utf16)) {
                    winner = copy
                }
            }
            var conflict = list.first(where: { $0.conflict != nil })?.conflict
            if Set(list.map(\.key)).count > 1 {
                var files: [String] = []
                for copy in list where !files.contains(copy.file) { files.append(copy.file) }
                conflict = "\(files.joined(separator: ", ")) give \(id) different content"
                conflicts.append(TruthConflict(id: id, files: files))
            }
            var entry = winner.entry
            admit(&entry, conflict: conflict, verifiable: list.contains { $0.entry.source?.version == 2 }, options: options)
            entries.append(entry)
        }
        return ParseResult(
            entries: entries,
            errors: errors,
            refused: false,
            transitions: reads.flatMap(\.read.transitions),
            held: reads.flatMap(\.read.held),
            lines: reads.flatMap(\.read.lines),
            head: nil,
            conflicts: conflicts
        )
    }

    /// Rank on the status lattice. A missing or unknown status ranks above
    /// every known one: it fails closed.
    private static func latticeRank(_ entry: TruthLedgerEntry) -> Int {
        guard let status = entry.statusValue else { return 4 }
        let known = entry.type == "TB" ? TruthFormat.tbStatuses : TruthFormat.uvStatuses
        return known.firstIndex(of: status) ?? 5
    }

    // MARK: One file

    private struct FileRead {
        var order: [String] = []
        var entries: [String: TruthLedgerEntry] = [:]
        /// JCS of what two copies of an entry must agree on.
        var bodyKeys: [String: String] = [:]
        var conflicts: [String: String] = [:]
        var transitions: [TruthTransition] = []
        var held: [TruthHeldTransition] = []
        var errors: [TruthReadError] = []
        var refused = false
        var lines: [TruthLineRecord] = []
        var head: TruthStreamHead?
    }

    private static func readFile(_ raw: [String], options: TruthReadOptions, file: String?) -> FileRead {
        var items: [(line: Int, decoded: DecodedTruthLine?)] = []
        var errors: [TruthReadError] = []
        var v2 = false

        for (i, text) in raw.enumerated() {
            if ecmaScriptTrim(text).isEmpty { continue }
            do {
                let decoded = try TruthFormat.decode(text)
                if decoded.version == 2 { v2 = true }
                if decoded.type == .proposal {
                    throw TruthLineError("a PROPOSAL line belongs in a proposals file, not a truth stream")
                }
                items.append((i + 1, decoded))
            } catch {
                items.append((i + 1, nil))
                if let declared = declaredVersion(text), TruthFormat.number(declared) != 1 { v2 = true }
                errors.append(TruthReadError(line: i + 1, error: String(describing: error), id: idOf(text), file: file))
            }
        }
        if v2 {
            // One writer's v2 stream holds only v2 lines: a version 1 line in it was not written by that writer
            for index in items.indices where items[index].decoded?.version == 1 {
                errors.append(TruthReadError(
                    line: items[index].line,
                    error: "a version 1 line inside a version 2 stream: the file is not one writer’s stream",
                    id: items[index].decoded?.id,
                    file: file
                ))
                items[index].decoded = nil
            }
        }
        for (index, error) in TruthFormat.checkChain(items.map(\.decoded)) {
            errors.append(TruthReadError(line: items[index].line, error: error, id: items[index].decoded?.id, file: file))
        }

        // A v2 stream is one unit: a refused line or a broken chain refuses all of it.
        // A pure v1 file keeps its per-line tolerance (it has no chain to break).
        if !errors.isEmpty, v2 { return FileRead(errors: errors.sorted { $0.line < $1.line }, refused: true) }
        var result = fold(items, options: options, file: file)
        result.errors = (errors + result.errors).sorted { $0.line < $1.line }
        if !result.errors.isEmpty, v2 { return FileRead(errors: result.errors, refused: true) }
        return result
    }

    /// The fold over a checked stream: entries, then the TRANSITIONs a reader honours, in stream (seq) order.
    private static func fold(_ items: [(line: Int, decoded: DecodedTruthLine?)], options: TruthReadOptions, file: String?) -> FileRead {
        var result = FileRead()
        var position: [String: Int] = [:]  // first stream position of each line id: what a cause.ref may name
        var transitions: [(transition: TruthTransition, at: Int)] = []

        for (at, item) in items.enumerated() {
            guard let d = item.decoded else { continue }
            let id = d.id
            if position[id] == nil { position[id] = at }
            result.lines.append(TruthLineRecord(line: item.line, text: d.text, version: d.version, type: d.type, id: id, seq: d.seq, hash: d.hash, file: file))
            if d.version == 2, let seq = d.seq, let hash = d.hash { result.head = TruthStreamHead(seq: seq, hash: hash) }
            if d.type == .transition {
                let transition = transitionOf(d, line: item.line, file: file)
                result.transitions.append(transition)
                transitions.append((transition, at))
                continue
            }
            // ADDENDUM / RULING: causes, kept in `lines`; TRANSITIONs carry their effect
            guard d.type == .tb || d.type == .uv else { continue }

            let entry = entryOf(d, line: item.line, file: file)
            let key = bodyKey(d)
            guard let prior = result.entries[id] else {
                result.order.append(id)
                result.entries[id] = entry
                result.bodyKeys[id] = key
                continue
            }
            if result.bodyKeys[id] != key {
                result.conflicts[id] = "lines \(prior.source?.line ?? 0) and \(item.line) give \(id) different content"
            }
            if d.version == 1 {
                // Version 1 re-emitted a line to change a status: the later line wins.
                // (A v2 stream states each entry once; its status changes are TRANSITIONs.)
                result.order.removeAll { $0 == id }
                result.order.append(id)
                result.entries[id] = entry
                result.bodyKeys[id] = key
            }
        }

        // The fold: the last honoured TRANSITION that targets an entry sets its status
        var floors: [String: String] = [:]  // the final status an entry reached, if any
        for (id, entry) in result.entries {
            if let status = entry.statusValue, isFinal(entry, status) { floors[id] = status }
        }
        for (t, at) in transitions {
            guard var entry = result.entries[t.target] else { continue }  // its target is not in the stream read
            func hold(_ reason: String) {
                result.held.append(TruthHeldTransition(line: t.line, id: t.id, reason: reason, file: file))
            }
            // Stenographer writes the cause's line first, or names no cause (ref null)
            if let ref = t.causeRef, !((position[ref] ?? Int.max) < at) {
                result.errors.append(TruthReadError(
                    line: t.line,
                    error: "TRANSITION \(t.id) names cause \(ref), which is not an earlier line of the stream",
                    id: t.id,
                    file: file
                ))
                continue
            }
            if let registry = options.signers, !registry.lists(t.author) {
                hold("TRANSITION \(t.id) is by '\(t.author)', whom the signer registry doesn't list: not applied")
                continue
            }
            let floor = floors[entry.id]
            let rank = statusRank(entry, t.status)
            if let floor, rank != -1, rank < statusRank(entry, floor) {
                hold("\(entry.type) \(entry.id) is \(floor), which is final: its TRANSITION to '\(t.status)' is not applied")
                continue
            }
            entry = applying(t, to: entry)
            result.entries[entry.id] = entry
            if isFinal(entry, t.status), floor == nil || rank > statusRank(entry, floor!) { floors[entry.id] = t.status }
        }
        return result
    }

    /// Statuses that never change again, except up the lattice (a strike after an override).
    private static func isFinal(_ entry: TruthLedgerEntry, _ status: String) -> Bool {
        entry.type == "TB" ? ["overridden", "struck"].contains(status) : ["verified", "refuted", "struck"].contains(status)
    }

    /// Index on the lattice, or -1 for a status this version doesn't know.
    private static func statusRank(_ entry: TruthLedgerEntry, _ status: String) -> Int {
        (entry.type == "TB" ? TruthFormat.tbStatuses : TruthFormat.uvStatuses).firstIndex(of: status) ?? -1
    }

    private static func applying(_ t: TruthTransition, to entry: TruthLedgerEntry) -> TruthLedgerEntry {
        switch entry {
        case .tb(var tb):
            tb.status = TbStatus(rawValue: t.status)
            tb.source?.transition = t
            return .tb(tb)
        case .uv(var uv):
            uv.status = UvStatus(rawValue: t.status)
            uv.source?.transition = t
            return .uv(uv)
        }
    }

    /// Sets `inadmissible` when a reader will not take the entry as truth whatever its status.
    private static func admit(_ entry: inout TruthLedgerEntry, conflict: String?, verifiable: Bool, options: TruthReadOptions) {
        func reason() -> TruthInadmissible? {
            if let conflict { return TruthInadmissible(reason: .conflict, detail: conflict) }
            if case .tb(let tb) = entry {
                guard let signer = tb.signedBy, !signer.isEmpty else {
                    return TruthInadmissible(reason: .unsigned, detail: "TB \(tb.id) has no signer: a backfilled TB is never truth on its own")
                }
                if !verifiable, !options.admitV1Tbs {
                    return TruthInadmissible(reason: .unverifiable, detail: "TB \(tb.id) is a version 1 line: it carries no hash, so its content can't be checked")
                }
            }
            if let registry = options.signers {
                let author: String
                switch entry {
                case .tb(let tb): author = tb.author
                case .uv(let uv): author = uv.author
                }
                if !registry.lists(author) {
                    return TruthInadmissible(reason: .unverifiable, detail: "\(entry.type) \(entry.id): author '\(author)' is not in the signer registry")
                }
                if case .tb(let tb) = entry, let signer = tb.signedBy, !registry.lists(signer) {
                    return TruthInadmissible(reason: .unverifiable, detail: "TB \(tb.id): signer '\(signer)' is not in the signer registry")
                }
            }
            // Agents settle only together, from different angles: an agent's TB is truth only with a
            // quorum of agents, and only when this reader knows every evidence kind it cites and every
            // link type it carries (it fails closed on one it doesn't, ahead of the quorum check, as
            // stenographer's import does)
            if case .tb(let tb) = entry, let signer = tb.signedBy, TruthQuorum.isAgent(signer, signers: options.signers) {
                if let unknown = unknownEvidenceKind(tb) {
                    return TruthInadmissible(
                        reason: .unknownValue,
                        detail: "TB \(tb.id) is signed by agent \(signer) and cites evidence kind '\(unknown.rawValue)', which this version "
                            + "doesn't know: it settles nothing for this reader, which can't tell that the quorum agrees from different angles"
                    )
                }
                if let unknown = unknownLinkType(tb) {
                    return TruthInadmissible(
                        reason: .unknownValue,
                        detail: "TB \(tb.id) is signed by agent \(signer) and carries link type '\(unknown)', which this version "
                            + "doesn't know: an agent's settlement carrying a value this reader can't read settles nothing for it"
                    )
                }
                if let why = agentSettlementIssue(tb, signers: options.signers) {
                    return TruthInadmissible(
                        reason: .agentWithoutQuorum,
                        detail: "TB \(tb.id) is signed by agent \(signer) with \(why): agents settle a claim only as two or more agent "
                            + "sessions agreeing from different angles within 15 minutes, or a person signs it"
                    )
                }
            }
            return nil
        }
        guard let refusal = reason() else { return }
        switch entry {
        case .tb(var tb): tb.inadmissible = refusal; entry = .tb(tb)
        case .uv(var uv): uv.inadmissible = refusal; entry = .uv(uv)
        }
    }

    /// The first evidence kind this version doesn't know that an agent's TB
    /// cites, on its line or in any member of its quorum, or nil. The quorum
    /// rules don't refuse a line over such a kind (it may be a newer writer's
    /// settling kind), so nothing shows this reader that the members settle
    /// from different angles: it fails closed (`unknown-value`), whatever its
    /// quorum, as stenographer's import does (truth format v2, "Agent
    /// quorum", Importing rule 5). With every kind known, the codec's rule 3
    /// has shown the angles.
    private static func unknownEvidenceKind(_ tb: TruthTbEntry) -> TruthEvidence.Kind? {
        let items = tb.evidence + (tb.quorum ?? []).flatMap(\.evidence)
        return items.first { !$0.kind.isKnown }?.kind
    }

    /// The first link type this version doesn't know in an agent's TB's
    /// `x-steno.links`, or nil. The codec doesn't judge such a link (it may be
    /// a newer writer's), and the quorum rules read only the link types a
    /// reader knows, so a quorum line carrying an unknown one is kept, and a
    /// reader that admits truth fails closed on it (truth format v2, "Unknown
    /// values"), as stenographer's import files it: `unknown-value`
    /// (Importing rule 5), whatever its quorum.
    private static func unknownLinkType(_ tb: TruthTbEntry) -> String? {
        guard case .object(let xSteno)? = tb.xSteno, case .array(let links)? = xSteno["links"] else { return nil }
        for case .object(let link) in links {
            if case .string(let type)? = link["type"], !TruthFormat.linkTypes.contains(type) { return type }
        }
        return nil
    }

    /// Why an agent-signed TB doesn't settle for this reader for want of a
    /// quorum of agents, or nil when it has one (the codec checked its rules).
    private static func agentSettlementIssue(_ tb: TruthTbEntry, signers: TruthSignerRegistry?) -> String? {
        guard let quorum = tb.quorum else { return "no quorum" }
        if let person = quorum.first(where: { !TruthQuorum.isMemberAgent($0.author, signers: signers) }) {
            let listed = signers.map { _ in "the signer registry doesn't list it as an agent" } ?? "its key doesn't start with \(TruthQuorum.agentPrefix)"
            return "a quorum that isn't all agents (quorum member \(person.author): \(listed))"
        }
        return nil
    }

    // MARK: Line → entry

    private static let tbKeys: Set<String> = ["id", "type", "ts", "author", "claim", "evidence", "signedBy", "literals", "quorum", "status", "x-steno"]
    private static let uvKeys: Set<String> = ["id", "type", "ts", "author", "assertion", "basis", "verifyBy", "contests", "status", "x-steno"]
    private static let chainKeys: Set<String> = ["schemaVersion", "seq", "prevHash", "hash"]

    private static func string(_ value: AnyCodableValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func entryOf(_ d: DecodedTruthLine, line: Int, file: String?) -> TruthLedgerEntry {
        let o = d.object
        let lineStatus = string(o["status"])
        let source = TruthEntrySource(version: d.version, text: d.text, line: line, seq: d.seq, hash: d.hash, lineStatus: lineStatus, file: file)
        let xSteno = o["x-steno"].map(JSONValue.init)
        let known = d.type == .tb ? tbKeys : uvKeys
        var extra: [String: JSONValue] = [:]
        for (key, value) in o where !known.contains(key) && !chainKeys.contains(key) {
            extra[key] = JSONValue(value)
        }
        let status = d.version == 1 ? v1Status(d, lineStatus) : lineStatus

        if d.type == .tb {
            var evidence: [TruthEvidence] = []
            if case .array(let list)? = o["evidence"] {
                for case .dict(let e) in list {
                    // Version 1 'command' evidence is read as claimed-command: stenographer never ran it
                    var kind = TruthEvidence.Kind(rawValue: string(e["kind"]) ?? "")
                    if d.version == 1, kind == .command { kind = .claimedCommand }
                    evidence.append(TruthEvidence(kind: kind, ref: string(e["ref"]) ?? "", detail: string(e["detail"])))
                }
            }
            var literals: [TruthTombstonedLiteral] = []
            if case .array(let list)? = o["literals"] {
                for case .dict(let l) in list {
                    literals.append(TruthTombstonedLiteral(dead: string(l["dead"]) ?? "", subject: string(l["subject"]), current: string(l["current"])))
                }
            }
            return .tb(TruthTbEntry(
                id: d.id,
                ts: string(o["ts"]) ?? "",
                author: string(o["author"]) ?? "",
                claim: string(o["claim"]) ?? "",
                evidence: evidence,
                signedBy: string(o["signedBy"]),
                status: status.map(TbStatus.init(rawValue:)),
                literals: literals,
                quorum: TruthQuorum.members(o["quorum"]),
                xSteno: xSteno,
                extra: extra,
                source: source
            ))
        }

        var verifyBy = TruthVerifyBy(kind: "", value: "")
        if case .dict(let v)? = o["verifyBy"] {
            verifyBy = TruthVerifyBy(kind: TruthVerifyBy.Kind(rawValue: string(v["kind"]) ?? ""), value: string(v["value"]) ?? "", detail: string(v["detail"]))
        }
        return .uv(TruthUvEntry(
            id: d.id,
            ts: string(o["ts"]) ?? "",
            author: string(o["author"]) ?? "",
            assertion: string(o["assertion"]) ?? "",
            basis: string(o["basis"]) ?? "",
            verifyBy: verifyBy,
            contests: string(o["contests"]),
            status: status.map(UvStatus.init(rawValue:)),
            xSteno: xSteno,
            extra: extra,
            source: source
        ))
    }

    /// A version 1 line's status. Stenographer 0.x exported a struck entry
    /// with its old status and an inbound `strikes` link (and, before it
    /// re-emitted a line, an inbound `overrides`, `verifies` or `refutes`):
    /// the links decide, up the lattice only. A missing or unknown status
    /// stays as it is (fail closed).
    private static func v1Status(_ d: DecodedTruthLine, _ lineStatus: String?) -> String? {
        guard var status = lineStatus else { return nil }
        let known = d.type == .tb ? TruthFormat.tbStatuses : TruthFormat.uvStatuses
        guard var rank = known.firstIndex(of: status) else { return status }
        guard case .dict(let x)? = d.object["x-steno"], case .array(let links)? = x["links"] else { return status }
        let effect: [String: String] = d.type == .tb
            ? ["strikes": "struck", "overrides": "overridden"]
            : ["strikes": "struck", "verifies": "verified", "refutes": "refuted"]
        for case .dict(let link) in links {
            guard string(link["toId"]) == d.id, string(link["fromId"]) != d.id,
                  let type = string(link["type"]), let next = effect[type], let nextRank = known.firstIndex(of: next), nextRank > rank
            else { continue }
            status = next
            rank = nextRank
        }
        return status
    }

    private static func transitionOf(_ d: DecodedTruthLine, line: Int, file: String?) -> TruthTransition {
        let o = d.object
        var causeKind = ""
        var causeRef: String?
        if case .dict(let cause)? = o["cause"] {
            causeKind = string(cause["kind"]) ?? ""
            causeRef = string(cause["ref"])
        }
        return TruthTransition(
            id: d.id,
            seq: d.seq ?? 0,
            ts: string(o["ts"]) ?? "",
            author: string(o["author"]) ?? "",
            target: string(o["target"]) ?? "",
            status: string(o["status"]) ?? "",
            causeKind: causeKind,
            causeRef: causeRef,
            line: line,
            file: file
        )
    }

    /// What two copies of one entry must agree on, compared as JCS bytes (key
    /// order never matters): its fields, unknown ones included (stenographer's
    /// Importing rules 2 and 10). The chain fields differ between two
    /// writers' copies of one entry, and `x-steno` is each ledger's own
    /// record, so neither counts; nor do `id`, `ts` and `status`.
    private static func bodyKey(_ d: DecodedTruthLine) -> String {
        let o = d.object
        let known = d.type == .tb ? tbKeys : uvKeys
        let unknown = o.filter { !known.contains($0.key) && !chainKeys.contains($0.key) }
        var body: [String: AnyCodableValue] = [
            "type": .string(d.type.rawValue),
            "author": o["author"] ?? .null,
            "extra": unknown.isEmpty ? .null : .dict(unknown),
        ]
        if d.type == .tb {
            var evidence = o["evidence"] ?? .null
            if d.version == 1, case .array(let list) = evidence {
                evidence = .array(list.map { item in
                    guard case .dict(var e) = item, e["kind"] == .string("command") else { return item }
                    e["kind"] = .string("claimed-command")
                    return .dict(e)
                })
            }
            body["claim"] = o["claim"] ?? .null
            body["evidence"] = evidence
            body["signedBy"] = o["signedBy"] ?? .null
            if case .array(let literals)? = o["literals"], !literals.isEmpty {
                body["literals"] = .array(literals)
            } else {
                body["literals"] = .null
            }
            body["quorum"] = o["quorum"] ?? .null
        } else {
            body["assertion"] = o["assertion"] ?? .null
            body["basis"] = o["basis"] ?? .null
            body["verifyBy"] = o["verifyBy"] ?? .null
            body["contests"] = o["contests"] ?? .null
        }
        return jsonText(.dict(body))
    }

    private static func declaredVersion(_ text: String) -> AnyCodableValue? {
        guard case .dict(let object)? = try? parseJSON(text) else { return nil }
        return object["schemaVersion"]
    }

    private static func idOf(_ text: String) -> String? {
        guard case .dict(let object)? = try? parseJSON(text) else { return nil }
        return string(object["id"])
    }

    // MARK: Serialization

    /// Serialize entries back to JSONL lines. An entry read from a stream is
    /// written back exactly as read (its status may have been folded from a
    /// later TRANSITION; the line's own never changes). An entry built in
    /// code is written in the version 1 shape, fields in stenographer's
    /// order, without a `quorum` (a version 1 line carries none: agents
    /// settle together only on v2 lines, which stenographer writes). A
    /// stream's TRANSITION, ADDENDUM and RULING lines are not entries: to
    /// write a whole stream back, write `ParseResult.lines`.
    public static func serialize(_ entries: [TruthLedgerEntry]) -> [String] {
        entries.map { $0.source?.text ?? handBuiltLine($0) }
    }

    private static func handBuiltLine(_ entry: TruthLedgerEntry) -> String {
        func optional(_ s: String?) -> String { s.map(jsonQuoted) ?? "null" }
        func evidenceJSON(_ e: TruthEvidence) -> String {
            jsonObject([("kind", jsonQuoted(e.kind.rawValue)), ("ref", jsonQuoted(e.ref))] + (e.detail.map { [("detail", jsonQuoted($0))] } ?? []))
        }
        func literalJSON(_ l: TruthTombstonedLiteral) -> String {
            jsonObject([("dead", jsonQuoted(l.dead))]
                + (l.subject.map { [("subject", jsonQuoted($0))] } ?? [])
                + (l.current.map { [("current", jsonQuoted($0))] } ?? []))
        }
        var members: [(String, String)]
        let xSteno: JSONValue?
        let extra: [String: JSONValue]
        switch entry {
        case .tb(let tb):
            members = [
                ("id", jsonQuoted(tb.id)), ("type", "\"TB\""), ("ts", jsonQuoted(tb.ts)), ("author", jsonQuoted(tb.author)),
                ("claim", jsonQuoted(tb.claim)), ("evidence", "[" + tb.evidence.map(evidenceJSON).joined(separator: ",") + "]"),
                ("signedBy", optional(tb.signedBy)),
            ]
            if !tb.literals.isEmpty { members.append(("literals", "[" + tb.literals.map(literalJSON).joined(separator: ",") + "]")) }
            if let status = tb.status { members.append(("status", jsonQuoted(status.rawValue))) }
            xSteno = tb.xSteno
            extra = tb.extra
        case .uv(let uv):
            let verifyBy = jsonObject([("kind", jsonQuoted(uv.verifyBy.kind.rawValue)), ("value", jsonQuoted(uv.verifyBy.value))]
                + (uv.verifyBy.detail.map { [("detail", jsonQuoted($0))] } ?? []))
            members = [
                ("id", jsonQuoted(uv.id)), ("type", "\"UV\""), ("ts", jsonQuoted(uv.ts)), ("author", jsonQuoted(uv.author)),
                ("assertion", jsonQuoted(uv.assertion)), ("basis", jsonQuoted(uv.basis)), ("verifyBy", verifyBy),
                ("contests", optional(uv.contests)),
            ]
            if let status = uv.status { members.append(("status", jsonQuoted(status.rawValue))) }
            xSteno = uv.xSteno
            extra = uv.extra
        }
        if let xSteno { members.append(("x-steno", jsonText(xSteno.anyCodableValue))) }
        for key in extra.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
            members.append((key, jsonText(extra[key]!.anyCodableValue)))
        }
        return jsonObject(members)
    }

    // MARK: Consumption rules (§7)

    /// Classify a single entry per the §7 consumption rules. Fails closed:
    /// anything but an active or contested, signed, admissible TB or an
    /// open, admissible UV — a struck entry, a status this version doesn't
    /// know, or none — is history.
    public static func classify(_ entry: TruthLedgerEntry) -> ConsumptionAction {
        if entry.inadmissible != nil { return .history }
        switch entry {
        case .tb(let tb):
            guard let signer = tb.signedBy, !signer.isEmpty else { return .history }  // unsigned: never truth on its own
            if tb.status == .active { return .groundTruth }
            if tb.status == .contested { return .contested }
            return .history  // overridden, struck, unknown or missing
        case .uv(let uv):
            // Open is a flag; verified minted a TB elsewhere, refuted is dead —
            // both are history here, as are struck and any unknown or missing status.
            return uv.status == .open ? .flag : .history
        }
    }

    /// Partition ledger entries into the selection compaction consumes. An
    /// open UV that contests a TB is attached to that TB whatever the TB's
    /// recorded status: a current TB with an open contest is carried as
    /// contested, with its contesting UVs — the dispute is never resolved
    /// silently. A UV contesting a TB that is not current truth stays in
    /// `unverified` on its own.
    public static func selectCurrentTruth(_ entries: [TruthLedgerEntry]) -> TruthSelection {
        var openContestsByTb: [String: [TruthUvEntry]] = [:]
        for case .uv(let uv) in entries where classify(.uv(uv)) == .flag {
            if let contested = uv.contests {
                openContestsByTb[contested, default: []].append(uv)
            }
        }

        var groundTruth: [TruthTbEntry] = []
        var contested: [(tombstone: TruthTbEntry, contestedBy: [TruthUvEntry])] = []
        var unverified: [TruthUvEntry] = []
        var history: [TruthLedgerEntry] = []

        for entry in entries {
            switch (classify(entry), entry) {
            case (.groundTruth, .tb(let tb)):
                if let open = openContestsByTb[tb.id] {
                    contested.append((tombstone: tb, contestedBy: open))
                } else {
                    groundTruth.append(tb)
                }
            case (.contested, .tb(let tb)):
                contested.append((tombstone: tb, contestedBy: openContestsByTb[tb.id] ?? []))
            case (.flag, .uv(let uv)):
                unverified.append(uv)
            default:
                history.append(entry)
            }
        }

        return TruthSelection(
            groundTruth: groundTruth,
            contested: contested,
            unverified: unverified,
            history: history
        )
    }

    /// The fold as a table, `{id: {type, status, current}}` for every entry —
    /// the shape of the truth-format fixtures' `*.expected.json`.
    public static func statusTable(_ entries: [TruthLedgerEntry]) -> [String: TruthStatusRow] {
        Dictionary(entries.map { ($0.id, TruthStatusRow(type: $0.type, status: $0.statusValue, current: classify($0) != .history)) },
                   uniquingKeysWith: { _, last in last })
    }
}
