import SwiftUI
import SmallChat

/// Surface for the most recent `tool_refinement_needed` payload returned
/// by the runtime. When no refinement has been emitted yet, the view
/// explains the contract so a developer reading the UI can see what would
/// land here.
struct RefinementView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Refinement")
                    .font(.largeTitle.bold())

                Text("When dispatch returns NONE-tier confidence, the runtime emits a structured `tool_refinement_needed` payload instead of guessing. The latest one is shown below.")
                    .foregroundStyle(.secondary)

                if let refinement = appState.lastRefinement {
                    refinementCard(refinement)
                } else {
                    GroupBox("No refinement yet") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Run a resolve in the Resolver panel against an artifact whose tools don't cover the intent. The resulting refinement payload appears here.")
                                .foregroundStyle(.secondary)
                            Text("MCP result type: tool_refinement_needed")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func refinementCard(_ refinement: ToolRefinement) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(alignment: .center, spacing: 8) {
                TierBadge(tier: refinement.proof.finalTier, confidence: nil)
                Text("for intent: \"\(refinement.originalIntent)\"")
                    .font(.system(.body, design: .default))
            }

            GroupBox("Reason") {
                Text(refinement.reason)
                    .font(.system(.body, design: .default))
                    .padding(4)
            }

            if !refinement.clarifyingQuestions.isEmpty {
                GroupBox("Clarifying questions") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(refinement.clarifyingQuestions.enumerated()), id: \.offset) { _, q in
                            Text("• \(q)")
                        }
                    }
                    .padding(4)
                }
            }

            if !refinement.nearMatches.isEmpty {
                GroupBox("Near matches") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(refinement.nearMatches.enumerated()), id: \.offset) { _, match in
                            HStack {
                                Text(match.toolName)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(String(format: "%.2f", match.confidence))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }
            }

            if !refinement.proof.steps.isEmpty {
                GroupBox("Proof trace (\(refinement.proof.totalElapsedMicroseconds)µs total)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(refinement.proof.steps.enumerated()), id: \.offset) { _, step in
                            HStack {
                                Text(step.stage)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(step.detail)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(step.elapsedMicroseconds)µs")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
    }
}
