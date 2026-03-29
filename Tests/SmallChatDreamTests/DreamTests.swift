import Testing
@testable import SmallChatDream

@Suite("Dream Module Tests")
struct DreamTests {
    // MARK: - Config Tests

    @Test("Default dream config has expected values")
    func defaultConfig() {
        let config = defaultDreamConfig
        #expect(config.autoDream == false)
        #expect(config.memoryPaths.isEmpty)
        #expect(config.logDir.isEmpty)
        #expect(config.maxRetainedVersions == 5)
        #expect(config.outputPath == "tools.toolkit.json")
        #expect(config.embedder == .local)
    }

    @Test("Load config returns defaults when no file exists")
    func loadConfigDefaults() {
        let config = loadDreamConfig(configPath: "/nonexistent/path/config.json")
        #expect(config.autoDream == false)
        #expect(config.outputPath == "tools.toolkit.json")
    }

    // MARK: - Tool Prioritizer Tests

    @Test("Prioritize tools with no data returns empty hints")
    func prioritizeNoData() {
        let hints = prioritizeTools([], [], ["tool_a", "tool_b"])
        #expect(hints.boosted.isEmpty)
        #expect(hints.demoted.isEmpty)
        #expect(hints.excluded.isEmpty)
    }

    @Test("High success rate boosts tool priority")
    func highSuccessRateBoosts() {
        let stats = [
            ToolUsageStats(
                toolName: "good_tool",
                totalCalls: 10,
                successCount: 9,
                failureCount: 1,
                switchAwayCount: 0,
                successRate: 0.9
            )
        ]
        let hints = prioritizeTools([], stats, ["good_tool"])
        #expect(hints.boosted["good_tool"] != nil)
    }

    @Test("Low success rate demotes tool priority")
    func lowSuccessRateDemotes() {
        let stats = [
            ToolUsageStats(
                toolName: "bad_tool",
                totalCalls: 10,
                successCount: 3,
                failureCount: 7,
                switchAwayCount: 5,
                successRate: 0.3
            )
        ]
        let hints = prioritizeTools([], stats, ["bad_tool"])
        #expect(hints.demoted["bad_tool"] != nil)
    }

    @Test("Negative memory mention with exclusion signal excludes tool")
    func negativeMentionExcludes() {
        let mentions = [
            MemoryToolMention(
                toolName: "old_tool",
                context: "don't use old_tool, it's deprecated",
                sentiment: .negative,
                source: "CLAUDE.md"
            )
        ]
        let hints = prioritizeTools(mentions, [], ["old_tool"])
        #expect(hints.excluded.contains("old_tool"))
    }

    @Test("Positive memory mention boosts tool")
    func positiveMentionBoosts() {
        let mentions = [
            MemoryToolMention(
                toolName: "great_tool",
                context: "I prefer great_tool, it works well",
                sentiment: .positive,
                source: "CLAUDE.md"
            )
        ]
        let hints = prioritizeTools(mentions, [], ["great_tool"])
        #expect(hints.boosted["great_tool"] != nil)
    }

    // MARK: - Memory Reader Tests

    @Test("Extract tool mentions finds known tools in text")
    func extractMentions() {
        let content = """
        I always use search_code for finding things.
        The read_file tool is also reliable.
        """
        let mentions = extractToolMentions(content, knownTools: ["search_code", "read_file", "unknown_tool"], source: "test.md")
        #expect(mentions.count == 2)
        let toolNames = Set(mentions.map(\.toolName))
        #expect(toolNames.contains("search_code"))
        #expect(toolNames.contains("read_file"))
    }

    @Test("Extract tool mentions infers positive sentiment")
    func extractPositiveSentiment() {
        let content = "I prefer search_code, it works well"
        let mentions = extractToolMentions(content, knownTools: ["search_code"], source: "test.md")
        #expect(mentions.first?.sentiment == .positive)
    }

    @Test("Extract tool mentions infers negative sentiment")
    func extractNegativeSentiment() {
        let content = "avoid broken_tool, it's buggy"
        let mentions = extractToolMentions(content, knownTools: ["broken_tool"], source: "test.md")
        #expect(mentions.first?.sentiment == .negative)
    }

    // MARK: - Log Analyzer Tests

    @Test("Aggregate usage stats groups by tool name")
    func aggregateStats() {
        let records = [
            ToolUsageRecord(toolName: "tool_a", timestamp: "2024-01-01", success: true, sessionId: "s1"),
            ToolUsageRecord(toolName: "tool_a", timestamp: "2024-01-02", success: true, sessionId: "s1"),
            ToolUsageRecord(toolName: "tool_a", timestamp: "2024-01-03", success: false, sessionId: "s1"),
            ToolUsageRecord(toolName: "tool_b", timestamp: "2024-01-01", success: true, sessionId: "s1"),
        ]
        let stats = aggregateUsageStats(records)
        #expect(stats.count == 2)

        let toolA = stats.first(where: { $0.toolName == "tool_a" })
        #expect(toolA?.totalCalls == 3)
        #expect(toolA?.successCount == 2)
        #expect(toolA?.failureCount == 1)
    }

    @Test("Discover log files returns empty for nonexistent directory")
    func discoverNoLogs() {
        let files = discoverLogFiles("/nonexistent/path")
        #expect(files.isEmpty)
    }

    // MARK: - Report Generation Tests

    @Test("Generate report produces readable output")
    func generateReportOutput() {
        let hints = ToolPriorityHints(
            boosted: ["good_tool": 1.3],
            demoted: ["bad_tool": 0.7],
            excluded: ["dead_tool"],
            reasoning: [
                "good_tool": "high success rate",
                "bad_tool": "low success rate",
                "dead_tool": "deprecated",
            ]
        )
        let report = generateReport(hints, [], [])
        #expect(report.contains("Dream Analysis Report"))
        #expect(report.contains("good_tool"))
        #expect(report.contains("bad_tool"))
        #expect(report.contains("dead_tool"))
    }

    // MARK: - Artifact Manifest Tests

    @Test("Artifact manifest round-trips through Codable")
    func artifactManifestCodable() throws {
        let version = ArtifactVersion(
            path: "/path/to/artifact.json",
            timestamp: "2024-01-01T00:00:00Z",
            isAutoGenerated: false,
            toolCount: 42,
            hash: "abc123"
        )
        let manifest = ArtifactManifest(
            currentVersion: "/path/to/current.json",
            versions: [version],
            lastManualVersion: "/path/to/manual.json"
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ArtifactManifest.self, from: data)
        #expect(decoded.currentVersion == manifest.currentVersion)
        #expect(decoded.versions.count == 1)
        #expect(decoded.versions[0].toolCount == 42)
        #expect(decoded.lastManualVersion == manifest.lastManualVersion)
    }
}
