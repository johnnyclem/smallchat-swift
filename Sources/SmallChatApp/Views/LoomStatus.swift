import SwiftUI
import SmallChat

/// Drop-in panel that surfaces loom-mcp detection + tool count. Designed
/// to be embedded in the Discovery view -- explicit so it doesn't fight
/// the existing layout.
struct LoomStatus: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GroupBox("loom-mcp") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(label)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Re-probe") { Task { await reprobe() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("Bundled manifest covers \(LoomMCPClient.knownToolNames.count) tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.loomLiveToolCount > 0 {
                    Text("Live server advertises \(appState.loomLiveToolCount) tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Default launch: npx -y @loom-mcp/server")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var icon: String {
        switch appState.loomDetection {
        case .present: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch appState.loomDetection {
        case .present: return .green
        case .missing: return .red
        case .unknown: return .gray
        }
    }

    private var label: String {
        switch appState.loomDetection {
        case .present: return "npx detected on PATH"
        case .missing: return "npx not found on PATH"
        case .unknown: return "PATH not inspected yet"
        }
    }

    @MainActor
    private func reprobe() async {
        appState.loomDetection = LoomDetection.probe()
    }
}
