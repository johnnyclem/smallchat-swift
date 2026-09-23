import Foundation

// MARK: - Wiki JSONL codec
//
// Reads and writes stenographer's append-only wiki JSONL format
// losslessly. One entry per line; later lines for the same id supersede
// earlier ones (the ledger is append-only, so a status change arrives as
// a re-emitted line). The `x-steno` key is preserved opaquely so
// `serialize(parse(lines)) == lines` field-for-field.

/// One line of the wiki's append-only JSONL ledger, as stenographer emits it.
struct WikiEntryLine: Codable {
    var id: String
    var type: String
    var ts: String?
    var author: String?
    // TB fields
    var claim: String?
    var evidence: [TruthEvidence]?
    var signedBy: String?
    var literals: [TruthTombstonedLiteral]?
    // UV fields
    var assertion: String?
    var basis: String?
    var verifyBy: TruthVerifyBy?
    var contests: String?
    var status: String?
    var xSteno: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, type, ts, author, claim, evidence, signedBy, literals
        case assertion, basis, verifyBy, contests, status
        case xSteno = "x-steno"
    }

    // Stenographer emits `signedBy` (TB) and `contests` (UV) as explicit
    // nulls, never omits them — encode to match the wire format exactly.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(ts, forKey: .ts)
        try container.encodeIfPresent(author, forKey: .author)
        if type == "TB" {
            try container.encodeIfPresent(claim, forKey: .claim)
            try container.encodeIfPresent(evidence, forKey: .evidence)
            try container.encode(signedBy, forKey: .signedBy)
            try container.encodeIfPresent(literals, forKey: .literals)
        } else {
            try container.encodeIfPresent(assertion, forKey: .assertion)
            try container.encodeIfPresent(basis, forKey: .basis)
            try container.encodeIfPresent(verifyBy, forKey: .verifyBy)
            try container.encode(contests, forKey: .contests)
        }
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(xSteno, forKey: .xSteno)
    }
}

public enum TruthWiki {

    // MARK: Line ↔ entry

    static func entry(from line: WikiEntryLine) throws -> TruthLedgerEntry {
        switch line.type {
        case "TB":
            return .tb(TruthTbEntry(
                id: line.id,
                ts: line.ts ?? "",
                author: line.author ?? "",
                claim: line.claim ?? "",
                evidence: line.evidence ?? [],
                signedBy: line.signedBy,
                status: TbStatus(rawValue: line.status ?? "") ?? .active,
                literals: line.literals ?? [],
                xSteno: line.xSteno
            ))
        case "UV":
            return .uv(TruthUvEntry(
                id: line.id,
                ts: line.ts ?? "",
                author: line.author ?? "",
                assertion: line.assertion ?? "",
                basis: line.basis ?? "",
                verifyBy: line.verifyBy ?? TruthVerifyBy(kind: .ask, value: line.author ?? ""),
                contests: line.contests,
                status: UvStatus(rawValue: line.status ?? "") ?? .open,
                xSteno: line.xSteno
            ))
        default:
            throw TruthError.malformedLine(line: 0, reason: "unsupported entry type: \(line.type)")
        }
    }

    static func line(from entry: TruthLedgerEntry) -> WikiEntryLine {
        switch entry {
        case .tb(let tb):
            return WikiEntryLine(
                id: tb.id,
                type: "TB",
                ts: tb.ts,
                author: tb.author,
                claim: tb.claim,
                evidence: tb.evidence,
                signedBy: tb.signedBy,
                literals: tb.literals.isEmpty ? nil : tb.literals,
                assertion: nil,
                basis: nil,
                verifyBy: nil,
                contests: nil,
                status: tb.status.rawValue,
                xSteno: tb.xSteno
            )
        case .uv(let uv):
            return WikiEntryLine(
                id: uv.id,
                type: "UV",
                ts: uv.ts,
                author: uv.author,
                claim: nil,
                evidence: nil,
                signedBy: nil,
                literals: nil,
                assertion: uv.assertion,
                basis: uv.basis,
                verifyBy: uv.verifyBy,
                contests: uv.contests,
                status: uv.status.rawValue,
                xSteno: uv.xSteno
            )
        }
    }

    // MARK: Parsing & serialization

    public struct ParseResult: Sendable {
        /// Deduplicated entries — the LAST line for each id wins (append-only ledger).
        public let entries: [TruthLedgerEntry]
        /// Lines that could not be parsed; the rest of the file is still usable.
        public let errors: [TruthError]
    }

    /// Parse raw JSONL (one blob or pre-split lines) into ledger entries.
    public static func parse(_ jsonl: String) -> ParseResult {
        parse(lines: jsonl.components(separatedBy: "\n"))
    }

    public static func parse(lines: [String]) -> ParseResult {
        let decoder = JSONDecoder()
        var order: [String] = []
        var byId: [String: TruthLedgerEntry] = [:]
        var errors: [TruthError] = []

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            do {
                let line = try decoder.decode(WikiEntryLine.self, from: Data(trimmed.utf8))
                let entry = try entry(from: line)
                if byId[entry.id] == nil {
                    order.append(entry.id)
                } else {
                    // Re-append so later lines keep append order.
                    order.removeAll { $0 == entry.id }
                    order.append(entry.id)
                }
                byId[entry.id] = entry
            } catch let error as TruthError {
                if case .malformedLine(_, let reason) = error {
                    errors.append(.malformedLine(line: index + 1, reason: reason))
                } else {
                    errors.append(error)
                }
            } catch {
                errors.append(.malformedLine(line: index + 1, reason: String(describing: error)))
            }
        }

        return ParseResult(entries: order.compactMap { byId[$0] }, errors: errors)
    }

    /// Serialize entries back to JSONL lines.
    public static func serialize(_ entries: [TruthLedgerEntry]) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return entries.compactMap { entry in
            guard let data = try? encoder.encode(line(from: entry)) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: Consumption rules (§7)

    /// Classify a single entry per the §7 consumption rules.
    public static func classify(_ entry: TruthLedgerEntry) -> ConsumptionAction {
        switch entry {
        case .tb(let tb):
            switch tb.status {
            case .active: return .groundTruth
            case .contested: return .contested
            case .overridden: return .history
            }
        case .uv(let uv):
            // Open is a flag; verified minted a TB elsewhere, refuted is
            // dead — both are history here.
            return uv.status == .open ? .flag : .history
        }
    }

    /// Partition ledger entries into the selection compaction consumes.
    /// Contested TBs are paired with their live contesting UVs so both
    /// carry through compaction — the dispute is never resolved silently.
    public static func selectCurrentTruth(_ entries: [TruthLedgerEntry]) -> TruthSelection {
        var openContestsByTb: [String: [TruthUvEntry]] = [:]
        for case .uv(let uv) in entries where uv.status == .open {
            if let contested = uv.contests {
                openContestsByTb[contested, default: []].append(uv)
            }
        }

        var groundTruth: [TruthTbEntry] = []
        var contested: [(tombstone: TruthTbEntry, contestedBy: [TruthUvEntry])] = []
        var unverified: [TruthUvEntry] = []
        var history: [TruthLedgerEntry] = []

        for entry in entries {
            switch classify(entry) {
            case .groundTruth:
                if case .tb(let tb) = entry { groundTruth.append(tb) }
            case .contested:
                if case .tb(let tb) = entry {
                    contested.append((tombstone: tb, contestedBy: openContestsByTb[tb.id] ?? []))
                }
            case .flag:
                if case .uv(let uv) = entry { unverified.append(uv) }
            case .history:
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
}
