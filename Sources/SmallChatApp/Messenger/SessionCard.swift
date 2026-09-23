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
            if let snapshot = model.liveActivity[agent.id] {
                ActivityFeed(snapshot: snapshot)
            } else if let activity = model.agentActivity[agent.id] {
                // A headless resume we started: its stream reports tools too.
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(activity).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(Theme.accent)
            }
            HStack {
                Text(agent.project)
                if let branch = agent.gitBranch {
                    Text("· \(branch)").lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(agent.lastActivity, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.handle), \(agent.activity.rawValue), \(agent.project)")
    }
}

/// Live tool activity: the step in flight, then the last few finished ones.
struct ActivityFeed: View {
    let snapshot: ActivitySnapshot
    /// Finished steps shown under the current one.
    var history = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let current = snapshot.current {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(current.label).lineLimit(1)
                }
                .foregroundStyle(Theme.accent)
                .help(current.label)
            } else if let said = snapshot.lastSaid {
                Text("“\(said)”")
                    .italic()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(said)
            }
            ForEach(snapshot.recent.filter(\.finished).suffix(history).reversed()) { step in
                HStack(spacing: 5) {
                    Image(systemName: step.failed ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(step.failed ? Color.red : Color.secondary)
                    Text(step.label).lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                .help(step.label)
            }
        }
        .font(.caption2)
        .animation(.easeOut(duration: 0.15), value: snapshot)
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
