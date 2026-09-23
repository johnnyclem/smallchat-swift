import SwiftUI
import SmallChatAgents

enum Theme {
    static let accent = Color.orange
    static let busy = Color.orange
    static let idle = Color.green
    static let stopped = Color.gray
    static let stenographer = Color.purple

    /// Stable per-handle avatar color.
    static func color(for handle: String) -> Color {
        let palette: [Color] = [.orange, .blue, .teal, .pink, .indigo, .mint, .cyan, .brown, .red, .green]
        var hash: UInt32 = 2_166_136_261
        for byte in handle.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static func activityColor(_ activity: AgentActivity) -> Color {
        switch activity {
        case .busy: return busy
        case .idle: return idle
        case .stopped: return stopped
        }
    }
}

/// One session in the sidebar: status, kind, durable name, project, recency.
struct SessionCard: View {
    @Environment(MessengerModel.self) private var model
    let agent: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.activityColor(agent.activity))
                    .frame(width: 7, height: 7)
                Text(agent.activity.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if agent.kind != .unknown {
                    KindChip(kind: agent.kind)
                }
            }
            Text(agent.handle)
                .font(.headline)
                .lineLimit(1)
            if let title = agent.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(agent.project)
                if let branch = agent.gitBranch {
                    Text("· \(branch)").lineLimit(1)
                }
                Spacer(minLength: 4)
                if let activity = model.agentActivity[agent.id] {
                    Label(activity, systemImage: "gearshape.2")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(agent.lastActivity, style: .relative)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.handle), \(agent.activity.rawValue), \(agent.project)")
    }
}

struct KindChip: View {
    let kind: AgentKind

    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case .interactive: return .blue
        case .background: return .green
        case .headless: return .purple
        case .unknown: return .gray
        }
    }
}

struct Avatar: View {
    let label: String
    let color: Color
    var systemImage: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(color.gradient)
            if let systemImage {
                Image(systemName: systemImage).font(.caption.weight(.bold))
            } else {
                Text(String(label.prefix(1)).uppercased()).font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
    }
}
