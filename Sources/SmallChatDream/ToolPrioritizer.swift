import Foundation

// MARK: - Scoring Constants

private let baseScore = 1.0
private let minScore = 0.5
private let maxScore = 2.0
private let minCallsForStats = 3
private let lowSuccessRate = 0.5
private let highSuccessRate = 0.85
private let highSwitchAwayRate = 0.3

/// Combine memory insights and usage statistics to generate priority hints.
///
/// Scoring logic:
/// - Frequency bonuses via logarithmic scaling (capped at 0.3)
/// - Success rate modifications (-0.3 to +0.15)
/// - Switch-away penalties (max 0.4)
/// - Memory sentiment bonuses/penalties (+0.3 / -0.4)
public func prioritizeTools(
    _ mentions: [MemoryToolMention],
    _ usageStats: [ToolUsageStats],
    _ knownTools: [String]
) -> ToolPriorityHints {
    var scores: [String: Double] = [:]
    var reasoning: [String: String] = [:]
    var excluded: Set<String> = []

    // Initialize all tools at base score
    for tool in knownTools {
        scores[tool] = baseScore
    }

    // Apply usage stat modifiers
    let statsByName: [String: ToolUsageStats] = Dictionary(
        usageStats.map { ($0.toolName, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    for (toolName, stats) in statsByName {
        guard stats.totalCalls >= minCallsForStats else { continue }
        var score = scores[toolName] ?? baseScore
        var reasons: [String] = []

        // Frequency bonus (log-scaled, capped at 0.3)
        let frequencyBonus = min(0.3, log(Double(stats.totalCalls)) / 10.0)
        score += frequencyBonus
        if frequencyBonus > 0.05 {
            reasons.append("frequency bonus +\(String(format: "%.2f", frequencyBonus)) (\(stats.totalCalls) calls)")
        }

        // Success rate modifier
        if stats.successRate < lowSuccessRate {
            let penalty = 0.3
            score -= penalty
            reasons.append("low success rate \(String(format: "%.0f", stats.successRate * 100))%: -\(String(format: "%.2f", penalty))")
        } else if stats.successRate >= highSuccessRate {
            let bonus = 0.15
            score += bonus
            reasons.append("high success rate \(String(format: "%.0f", stats.successRate * 100))%: +\(String(format: "%.2f", bonus))")
        }

        // Switch-away penalty
        if stats.totalCalls > 0 {
            let switchRate = Double(stats.switchAwayCount) / Double(stats.totalCalls)
            if switchRate > highSwitchAwayRate {
                let penalty = min(0.4, switchRate)
                score -= penalty
                reasons.append("high switch-away rate \(String(format: "%.0f", switchRate * 100))%: -\(String(format: "%.2f", penalty))")
            }
        }

        scores[toolName] = score
        if !reasons.isEmpty {
            reasoning[toolName] = reasons.joined(separator: "; ")
        }
    }

    // Apply memory sentiment modifiers
    let mentionsByTool: [String: [MemoryToolMention]] = Dictionary(
        grouping: mentions,
        by: \.toolName
    )

    for (toolName, toolMentions) in mentionsByTool {
        var score = scores[toolName] ?? baseScore
        let positiveCount = toolMentions.filter { $0.sentiment == .positive }.count
        let negativeCount = toolMentions.filter { $0.sentiment == .negative }.count

        if positiveCount > 0 {
            let bonus = min(0.3, Double(positiveCount) * 0.1)
            score += bonus
            let existing = reasoning[toolName].map { $0 + "; " } ?? ""
            reasoning[toolName] = existing + "positive memory mentions: +\(String(format: "%.2f", bonus))"
        }

        if negativeCount > 0 {
            let penalty = min(0.4, Double(negativeCount) * 0.15)
            score -= penalty
            let existing = reasoning[toolName].map { $0 + "; " } ?? ""
            reasoning[toolName] = existing + "negative memory mentions: -\(String(format: "%.2f", penalty))"

            // Check for explicit exclusion signals
            let hasExclusionSignal = toolMentions.contains { mention in
                let lower = mention.context.lowercased()
                return lower.contains("don't use") || lower.contains("do not use")
                    || lower.contains("avoid") || lower.contains("deprecated")
                    || lower.contains("replaced by")
            }
            if hasExclusionSignal {
                excluded.insert(toolName)
                let existing = reasoning[toolName].map { $0 + "; " } ?? ""
                reasoning[toolName] = existing + "excluded: explicit negative signal in memory"
            }
        }

        scores[toolName] = score
    }

    // Clamp and classify
    var boosted: [String: Double] = [:]
    var demoted: [String: Double] = [:]

    for (toolName, rawScore) in scores {
        let clamped = max(minScore, min(maxScore, rawScore))
        if clamped > baseScore {
            boosted[toolName] = clamped
        } else if clamped < baseScore {
            demoted[toolName] = clamped
        }
    }

    return ToolPriorityHints(
        boosted: boosted,
        demoted: demoted,
        excluded: excluded,
        reasoning: reasoning
    )
}

/// Generate a human-readable report summarizing dream analysis.
public func generateReport(
    _ hints: ToolPriorityHints,
    _ usageStats: [ToolUsageStats],
    _ mentions: [MemoryToolMention]
) -> String {
    var lines: [String] = []
    lines.append("=== Dream Analysis Report ===")
    lines.append("")

    let totalCalls = usageStats.reduce(0) { $0 + $1.totalCalls }
    lines.append("Total tool calls analyzed: \(totalCalls)")
    lines.append("Memory mentions found: \(mentions.count)")
    lines.append("")

    if !hints.boosted.isEmpty {
        lines.append("Boosted tools (\(hints.boosted.count)):")
        for (tool, factor) in hints.boosted.sorted(by: { $0.value > $1.value }) {
            let reason = hints.reasoning[tool] ?? "—"
            lines.append("  + \(tool): \(String(format: "%.2f", factor))x (\(reason))")
        }
        lines.append("")
    }

    if !hints.demoted.isEmpty {
        lines.append("Demoted tools (\(hints.demoted.count)):")
        for (tool, factor) in hints.demoted.sorted(by: { $0.value < $1.value }) {
            let reason = hints.reasoning[tool] ?? "—"
            lines.append("  - \(tool): \(String(format: "%.2f", factor))x (\(reason))")
        }
        lines.append("")
    }

    if !hints.excluded.isEmpty {
        lines.append("Excluded tools (\(hints.excluded.count)):")
        for tool in hints.excluded.sorted() {
            let reason = hints.reasoning[tool] ?? "—"
            lines.append("  x \(tool) (\(reason))")
        }
        lines.append("")
    }

    if hints.boosted.isEmpty && hints.demoted.isEmpty && hints.excluded.isEmpty {
        lines.append("No priority changes — all tools at baseline.")
        lines.append("")
    }

    return lines.joined(separator: "\n")
}
