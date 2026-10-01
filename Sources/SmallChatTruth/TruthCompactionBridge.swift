import Foundation
import SmallChatCompaction

// MARK: - Compaction bridge
//
// Wires the truth ledger into compaction at the JSONL seam (Option B):
// current truth is ingested as high-priority corpus items that survive
// compaction, and the verifier gains a stock invariant that fails any
// compaction which drops a truth item or strips the UNVERIFIED marker.
//
// The contract (§7):
//   - Active TB      → ground truth: compacted, citable.
//   - Contested TB   → carried WITH its contesting UVs; the dispute is
//                      never resolved silently in either direction. An
//                      active TB with an open contesting UV is carried as
//                      contested too, even before a TRANSITION says so.
//   - Open UV        → flagged `UNVERIFIED`; compaction never promotes a
//                      UV into something that reads as proven, and never
//                      drops one.
//   - History        → excluded (struck, overridden, refuted, verified,
//                      and any unknown or missing status); stale copies
//                      are displaced on re-sync.
//
// Rendering uses the suite's frozen markers (`[TB]`, `[TB ⚠ CONTESTED]`,
// `[UV — UNVERIFIED]`) and escapes them inside ledger fields.

public enum TruthCompaction {

    /// The id prefix truth-derived corpus items carry.
    public static let itemIdPrefix = "truth:"

    /// The dragon marker. If this ever disappears from a UV's rendering,
    /// the UV has been silently promoted to proven — a contract violation.
    public static let unverifiedMarker = "[UV — UNVERIFIED]"

    // MARK: Rendering

    /// Ledger fields are untrusted text: one line, no forged markers.
    static func field(_ text: String) -> String {
        TruthEscaping.escapeUntrusted(text, singleLine: true)
    }

    private static func signature(_ tb: TruthTbEntry) -> String {
        tb.signedBy.map { "signed: \(field($0))" } ?? "unsigned"
    }

    static func render(tb: TruthTbEntry) -> String {
        "[TB] \(field(tb.claim)) (\(signature(tb)), evidence: \(tb.evidence.count))"
    }

    static func render(contested tb: TruthTbEntry, contestedBy: [TruthUvEntry]) -> String {
        var text = "[TB ⚠ CONTESTED] \(field(tb.claim)) (\(signature(tb)))"
        for uv in contestedBy {
            text += "\n  disputed by \(unverifiedMarker) \(field(uv.assertion)) (\(field(uv.author)))"
        }
        return text
    }

    static func render(uv: TruthUvEntry) -> String {
        let contests = uv.contests.map { "; contests \(field($0))" } ?? ""
        return "\(unverifiedMarker) \(field(uv.assertion)) (basis: \(field(uv.basis)); verify by \(field(uv.verifyBy.kind.rawValue)): \(field(uv.verifyBy.value))\(contests))"
    }

    /// The open UVs rendered on their own: every one that doesn't ride a
    /// contested TB in the selection — including a UV contesting a TB that
    /// isn't current truth, or isn't loaded. Each open UV appears exactly
    /// once, beside its TB or here; none is ever dropped.
    static func standaloneUnverified(_ selection: TruthSelection) -> [TruthUvEntry] {
        let attached = selection.attachedUvIds
        return selection.unverified.filter { !attached.contains($0.id) }
    }

    /// Render a truth selection as the markdown block appended to
    /// compacted summaries and given to the stenographer as its brief.
    /// Markers are load-bearing: `[TB]` may be relied on, `[TB ⚠ CONTESTED]`
    /// carries its dispute, and the UNVERIFIED marker must never be dropped
    /// by deeper compaction. Ledger fields are escaped
    /// (`TruthEscaping.escapeUntrusted`), so a field can never forge a
    /// marker or a line.
    public static func renderSection(_ selection: TruthSelection) -> String {
        var lines = ["## Asserted Truth (ledger)"]
        let standalone = standaloneUnverified(selection)
        if selection.groundTruth.isEmpty, selection.contested.isEmpty, standalone.isEmpty {
            lines.append("(no current truth entries)")
            return lines.joined(separator: "\n")
        }
        for tb in selection.groundTruth {
            lines.append("- " + render(tb: tb))
        }
        for pair in selection.contested {
            lines.append("- " + render(contested: pair.tombstone, contestedBy: pair.contestedBy))
        }
        for uv in standalone {
            lines.append("- " + render(uv: uv))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Corpus items

    /// Project current truth into compaction corpus items. These are the
    /// durable residue: append them to a corpus before compaction and
    /// verify with `TruthInvariants.preserved(_:)` after. A contested TB's
    /// item carries its contesting UVs; every other open UV is an item of
    /// its own.
    public static func compactionItems(_ selection: TruthSelection) -> [CompactionItem] {
        var items: [CompactionItem] = []
        for tb in selection.groundTruth {
            items.append(CompactionItem(id: itemIdPrefix + tb.id, text: render(tb: tb)))
        }
        for pair in selection.contested {
            items.append(CompactionItem(
                id: itemIdPrefix + pair.tombstone.id,
                text: render(contested: pair.tombstone, contestedBy: pair.contestedBy)
            ))
        }
        for uv in standaloneUnverified(selection) {
            items.append(CompactionItem(id: itemIdPrefix + uv.id, text: render(uv: uv)))
        }
        return items
    }

    // MARK: L4-shaped records

    /// An invariant record with the confidence type riding along — the
    /// two-axes-not-one contract for string-typed invariant stores.
    public struct InvariantRecord: Sendable, Equatable {
        public let key: String
        public let value: String
        public let confidence: TruthConfidence
        public let contested: Bool
    }

    /// Project the selection into L4-shaped records. An L4 invariant is
    /// very often actually a UV — tribal knowledge that compacted well but
    /// was never verified — so the marker travels inside the value.
    public static func invariantRecords(_ selection: TruthSelection) -> [InvariantRecord] {
        var records: [InvariantRecord] = []
        for tb in selection.groundTruth {
            records.append(InvariantRecord(
                key: itemIdPrefix + tb.id,
                value: "[TB] \(field(tb.claim))",
                confidence: .tb,
                contested: false
            ))
        }
        for pair in selection.contested {
            let disputes = pair.contestedBy.map { field($0.assertion) }.joined(separator: " | ")
            let suffix = disputes.isEmpty ? "" : " — disputed: \(disputes)"
            records.append(InvariantRecord(
                key: itemIdPrefix + pair.tombstone.id,
                value: "[TB ⚠ CONTESTED] \(field(pair.tombstone.claim))\(suffix)",
                confidence: .tb,
                contested: true
            ))
        }
        for uv in standaloneUnverified(selection) {
            records.append(InvariantRecord(
                key: itemIdPrefix + uv.id,
                value: "\(unverifiedMarker) \(field(uv.assertion))",
                confidence: .uv,
                contested: false
            ))
        }
        return records
    }
}

// MARK: - Stock verifier invariants

public enum TruthInvariants {

    /// Every current-truth item must survive compaction, and no surviving
    /// UV may lose its UNVERIFIED marker (silent promotion to proven).
    public static func preserved(_ selection: TruthSelection) -> CompactionVerifier.Invariant {
        let required = TruthCompaction.compactionItems(selection)
        // Standalone UVs, and contested TBs that carry their disputing UVs
        let unverifiedIds = Set(
            TruthCompaction.standaloneUnverified(selection).map { TruthCompaction.itemIdPrefix + $0.id }
                + selection.contested.filter { !$0.contestedBy.isEmpty }.map { TruthCompaction.itemIdPrefix + $0.tombstone.id }
        )
        return { _, after in
            let afterById = Dictionary(after.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            var violations: [String] = []
            for item in required {
                guard let text = afterById[item.id] else {
                    violations.append("truth entry \(item.id) was dropped by compaction")
                    continue
                }
                if unverifiedIds.contains(item.id), !text.contains(TruthCompaction.unverifiedMarker) {
                    violations.append("truth entry \(item.id) lost its UNVERIFIED marker — a UV must never read as proven")
                }
            }
            return violations.isEmpty ? nil : violations.joined(separator: "; ")
        }
    }
}
