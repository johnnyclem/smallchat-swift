import SwiftUI
import SmallChat

/// Small inline badge that visualizes a `DispatchTier`. Used by the
/// Resolver and Refinement panels to make the per-result tier obvious.
struct TierBadge: View {
    let tier: DispatchTier
    let confidence: Double?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.primary)
            if let confidence {
                Text(String(format: "%.2f", confidence))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var label: String {
        switch tier {
        case .exact:  return "EXACT"
        case .high:   return "HIGH"
        case .medium: return "MEDIUM"
        case .low:    return "LOW"
        case .none:   return "NONE"
        }
    }

    private var color: Color {
        switch tier {
        case .exact:  return .green
        case .high:   return .mint
        case .medium: return .yellow
        case .low:    return .orange
        case .none:   return .red
        }
    }
}
