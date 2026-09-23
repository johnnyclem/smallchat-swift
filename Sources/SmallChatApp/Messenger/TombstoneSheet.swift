import SwiftUI
import SmallChatAgents
import SmallChatTruth

/// Author and sign a tombstone: what's dead, the evidence, and the literals
/// the stenographer should object to from now on.
struct TombstoneSheet: View {
    @Environment(MessengerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Optional starting point (e.g. the chat message it came from).
    var prefill: TombstoneDraft = TombstoneDraft()

    @State private var claim = ""
    @State private var evidence: [EvidenceRow] = []
    @State private var literals: [LiteralRow] = []
    @State private var signer = ""
    @State private var error: String?

    struct EvidenceRow: Identifiable {
        let id = UUID()
        var kind: TruthEvidence.Kind = .commit
        var ref = ""
        var detail = ""
    }

    struct LiteralRow: Identifiable {
        let id = UUID()
        var subject = ""
        var dead = ""
        var current = ""

        var literal: TruthTombstonedLiteral {
            TruthTombstonedLiteral(dead: dead, subject: subject.isEmpty ? nil : subject, current: current.isEmpty ? nil : current)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tombstone").font(.headline)
            Text("Assert that something is dead, with evidence. Literals are the exact values the stenographer will object to when an agent uses them again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claim").font(.subheadline.weight(.medium))
                        TextEditor(text: $claim)
                            .font(.body)
                            .frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        Text("e.g. “LOG_BUDGET 30 is dead; the budget is 100.”").font(.caption2).foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Evidence").font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Add") { evidence.append(EvidenceRow()) }.controlSize(.small)
                        }
                        ForEach($evidence) { $row in
                            HStack {
                                Picker("", selection: $row.kind) {
                                    ForEach(evidenceKinds, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 110)
                                TextField("ref (sha, file:line, test…)", text: $row.ref)
                                TextField("detail (optional)", text: $row.detail)
                                removeButton { evidence.removeAll { $0.id == row.id } }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Literals").font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Add") { literals.append(LiteralRow()) }.controlSize(.small)
                        }
                        if literals.isEmpty {
                            Text("Optional, but without literals the stenographer can't object to this tombstone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach($literals) { $row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    TextField("subject (e.g. LOG_BUDGET)", text: $row.subject)
                                    TextField("dead value", text: $row.dead)
                                    TextField("current (optional)", text: $row.current)
                                    removeButton { literals.removeAll { $0.id == row.id } }
                                }
                                if !row.dead.isEmpty, let reason = row.literal.validationError() {
                                    Text(reason).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    LabeledContent("Sign as") {
                        TextField("your name", text: $signer).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Written to") {
                        Text(model.tombstoneTarget ?? "no wiki file configured")
                            .font(.caption.monospaced())
                            .foregroundStyle(model.tombstoneTarget == nil ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let first = draft.problems().first {
                Text(first).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign Tombstone", action: sign)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.problems().isEmpty || model.tombstoneTarget == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
        .onAppear(perform: load)
    }

    private let evidenceKinds: [TruthEvidence.Kind] = [.commit, .file, .test, .command, .wiki, .message]

    private var draft: TombstoneDraft {
        TombstoneDraft(
            claim: claim,
            evidence: evidence.map { TruthEvidence(kind: $0.kind, ref: $0.ref, detail: $0.detail.isEmpty ? nil : $0.detail) },
            literals: literals.filter { !($0.dead.isEmpty && $0.subject.isEmpty && $0.current.isEmpty) }.map(\.literal),
            signer: signer
        )
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    private func load() {
        claim = prefill.claim
        evidence = prefill.evidence.map { EvidenceRow(kind: $0.kind, ref: $0.ref, detail: $0.detail ?? "") }
        if evidence.isEmpty { evidence = [EvidenceRow()] }
        literals = prefill.literals.map { LiteralRow(subject: $0.subject ?? "", dead: $0.dead, current: $0.current ?? "") }
        if literals.isEmpty { literals = [LiteralRow()] }
        signer = prefill.signer.isEmpty ? model.settings.signerIdentity : prefill.signer
    }

    private func sign() {
        do {
            try model.assertTombstone(draft)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
