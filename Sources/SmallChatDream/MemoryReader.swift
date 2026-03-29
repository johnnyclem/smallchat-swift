import Foundation

/// Standard memory file locations to scan.
private let standardMemoryPaths: [String] = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        home + "/.claude/CLAUDE.md",
        "CLAUDE.md",
    ]
}()

/// Positive sentiment patterns in memory text.
private let positivePatterns: [String] = [
    "prefer", "works well", "reliable", "recommended", "useful",
    "great", "love", "always use", "best", "favorite", "favourite",
    "excellent", "go-to", "essential", "must-have",
]

/// Negative sentiment patterns in memory text.
private let negativePatterns: [String] = [
    "avoid", "broken", "buggy", "deprecated", "unreliable",
    "slow", "don't use", "do not use", "problematic", "issues with",
    "flaky", "unstable", "replaced by", "superseded",
]

/// Read memory files from standard locations and user-configured paths.
///
/// Returns structured content for each readable memory file found.
public func readMemoryFiles(_ config: DreamConfig, projectDir: String) -> [MemoryFileContent] {
    let fm = FileManager.default
    var results: [MemoryFileContent] = []

    // Collect all paths to check
    var paths = standardMemoryPaths.map { path -> String in
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return path
        }
        return projectDir + "/" + path
    }
    paths.append(contentsOf: config.memoryPaths.map { path in
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return path
        }
        return projectDir + "/" + path
    })

    for path in paths {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath),
              let content = try? String(contentsOfFile: expandedPath, encoding: .utf8),
              !content.isEmpty else {
            continue
        }

        var modifiedAt = Date()
        if let attrs = try? fm.attributesOfItem(atPath: expandedPath),
           let date = attrs[.modificationDate] as? Date {
            modifiedAt = date
        }

        results.append(MemoryFileContent(
            path: expandedPath,
            content: content,
            modifiedAt: modifiedAt
        ))
    }

    return results
}

/// Extract tool mentions from memory file content with inferred sentiment.
///
/// Searches each line for known tool names (word-boundary match), captures
/// surrounding context (1 line above and below), and infers sentiment from
/// pattern matching on the context.
public func extractToolMentions(
    _ content: String,
    knownTools: [String],
    source: String
) -> [MemoryToolMention] {
    let lines = content.components(separatedBy: .newlines)
    var mentions: [MemoryToolMention] = []

    for (lineIndex, line) in lines.enumerated() {
        let lowered = line.lowercased()

        for toolName in knownTools {
            // Word-boundary-style match
            guard lowered.contains(toolName.lowercased()) else { continue }

            // Build context: surrounding lines
            let startIdx = max(0, lineIndex - 1)
            let endIdx = min(lines.count - 1, lineIndex + 1)
            let contextLines = lines[startIdx...endIdx]
            let context = contextLines.joined(separator: "\n")

            let sentiment = inferSentiment(context)
            mentions.append(MemoryToolMention(
                toolName: toolName,
                context: context,
                sentiment: sentiment,
                source: source
            ))
        }
    }

    return mentions
}

/// Infer sentiment from context text using positive/negative pattern matching.
private func inferSentiment(_ context: String) -> MemoryToolMention.Sentiment {
    let lowered = context.lowercased()
    let hasPositive = positivePatterns.contains { lowered.contains($0) }
    let hasNegative = negativePatterns.contains { lowered.contains($0) }

    if hasPositive && !hasNegative { return .positive }
    if hasNegative && !hasPositive { return .negative }
    return .neutral
}
