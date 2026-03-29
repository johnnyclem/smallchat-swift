import Foundation

// MARK: - Log Analysis Types

/// A single observed tool usage extracted from Claude session logs.
public struct ToolUsageRecord: Sendable, Codable {
    public let toolName: String
    public let providerId: String?
    public let timestamp: String
    public let success: Bool
    /// True if the user immediately requested a different tool after this one.
    public var userSwitchedAway: Bool
    public let sessionId: String
    public let durationMs: Double?

    public init(
        toolName: String,
        providerId: String? = nil,
        timestamp: String,
        success: Bool,
        userSwitchedAway: Bool = false,
        sessionId: String,
        durationMs: Double? = nil
    ) {
        self.toolName = toolName
        self.providerId = providerId
        self.timestamp = timestamp
        self.success = success
        self.userSwitchedAway = userSwitchedAway
        self.sessionId = sessionId
        self.durationMs = durationMs
    }
}

/// Aggregated statistics for a tool derived from log analysis.
public struct ToolUsageStats: Sendable {
    public let toolName: String
    public let providerId: String?
    public let totalCalls: Int
    public let successCount: Int
    public let failureCount: Int
    /// Times the user asked for a different tool immediately after this one.
    public let switchAwayCount: Int
    /// Success rate as a fraction (0-1).
    public let successRate: Double
    public let avgDurationMs: Double?

    public init(
        toolName: String,
        providerId: String? = nil,
        totalCalls: Int,
        successCount: Int,
        failureCount: Int,
        switchAwayCount: Int,
        successRate: Double,
        avgDurationMs: Double? = nil
    ) {
        self.toolName = toolName
        self.providerId = providerId
        self.totalCalls = totalCalls
        self.successCount = successCount
        self.failureCount = failureCount
        self.switchAwayCount = switchAwayCount
        self.successRate = successRate
        self.avgDurationMs = avgDurationMs
    }
}

// MARK: - Memory Analysis Types

/// Content read from a single memory file.
public struct MemoryFileContent: Sendable {
    public let path: String
    public let content: String
    public let modifiedAt: Date

    public init(path: String, content: String, modifiedAt: Date) {
        self.path = path
        self.content = content
        self.modifiedAt = modifiedAt
    }
}

/// A tool mention extracted from a memory file with inferred sentiment.
public struct MemoryToolMention: Sendable {
    public let toolName: String
    /// Surrounding text from the memory file that mentions this tool.
    public let context: String
    public let sentiment: Sentiment
    /// Which memory file this mention was found in.
    public let source: String

    public init(toolName: String, context: String, sentiment: Sentiment, source: String) {
        self.toolName = toolName
        self.context = context
        self.sentiment = sentiment
        self.source = source
    }

    public enum Sentiment: String, Sendable, Codable {
        case positive
        case negative
        case neutral
    }
}

// MARK: - Priority Hints

/// Priority hints that influence compilation output.
public struct ToolPriorityHints: Sendable {
    /// Tools to boost -- toolName to boost factor (>1.0 = boosted).
    public var boosted: [String: Double]
    /// Tools to demote -- toolName to demotion factor (<1.0 = demoted).
    public var demoted: [String: Double]
    /// Tools to exclude entirely from the compiled artifact.
    public var excluded: Set<String>
    /// Human-readable reasoning for each priority decision.
    public var reasoning: [String: String]

    public init(
        boosted: [String: Double] = [:],
        demoted: [String: Double] = [:],
        excluded: Set<String> = [],
        reasoning: [String: String] = [:]
    ) {
        self.boosted = boosted
        self.demoted = demoted
        self.excluded = excluded
        self.reasoning = reasoning
    }
}

// MARK: - Dream Analysis Result

/// Complete result of a dream analysis pass.
public struct DreamAnalysis: Sendable {
    public let memoryMentions: [MemoryToolMention]
    public let usageStats: [ToolUsageStats]
    public let priorityHints: ToolPriorityHints
    /// Human-readable summary report.
    public let report: String
    public let timestamp: String

    public init(
        memoryMentions: [MemoryToolMention],
        usageStats: [ToolUsageStats],
        priorityHints: ToolPriorityHints,
        report: String,
        timestamp: String
    ) {
        self.memoryMentions = memoryMentions
        self.usageStats = usageStats
        self.priorityHints = priorityHints
        self.report = report
        self.timestamp = timestamp
    }
}

/// Result returned by compileLatest() / dream().
public struct DreamResult: Sendable {
    public let analysis: DreamAnalysis
    /// Path to the newly compiled artifact (or nil if dry-run).
    public let artifactPath: String?
    /// Path to the archived previous artifact.
    public let archivedPath: String?
    /// Whether the new artifact was automatically promoted.
    public let autoPromoted: Bool

    public init(
        analysis: DreamAnalysis,
        artifactPath: String? = nil,
        archivedPath: String? = nil,
        autoPromoted: Bool = false
    ) {
        self.analysis = analysis
        self.artifactPath = artifactPath
        self.archivedPath = archivedPath
        self.autoPromoted = autoPromoted
    }
}

// MARK: - Artifact Versioning

/// Metadata for a single versioned artifact.
public struct ArtifactVersion: Sendable, Codable {
    /// Absolute path to the artifact file.
    public let path: String
    public let timestamp: String
    /// True if this version was generated by auto-dream.
    public let isAutoGenerated: Bool
    /// Dream analysis that produced this version (if applicable).
    public let toolCount: Int
    /// SHA-256 hash of the artifact file content.
    public let hash: String

    public init(
        path: String,
        timestamp: String,
        isAutoGenerated: Bool,
        toolCount: Int,
        hash: String
    ) {
        self.path = path
        self.timestamp = timestamp
        self.isAutoGenerated = isAutoGenerated
        self.toolCount = toolCount
        self.hash = hash
    }
}

/// Manifest tracking all artifact versions for a project.
public struct ArtifactManifest: Sendable, Codable {
    /// Path to the currently active artifact.
    public var currentVersion: String
    /// All tracked artifact versions, newest first.
    public var versions: [ArtifactVersion]
    /// Path to the last non-auto-generated version (always retained as fallback).
    public var lastManualVersion: String?

    public init(
        currentVersion: String = "",
        versions: [ArtifactVersion] = [],
        lastManualVersion: String? = nil
    ) {
        self.currentVersion = currentVersion
        self.versions = versions
        self.lastManualVersion = lastManualVersion
    }
}
