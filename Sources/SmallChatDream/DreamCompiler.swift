import Foundation
import SmallChatCore
import SmallChatCompiler
import SmallChatEmbedding

/// Options for the dream compilation pipeline.
public struct CompileLatestOptions: Sendable {
    /// Override config values.
    public var configOverrides: DreamConfig?
    /// Path to config file.
    public var configPath: String?
    /// If true, analyze only -- don't compile or write artifacts.
    public var dryRun: Bool
    /// Project directory (defaults to cwd).
    public var projectDir: String?

    public init(
        configOverrides: DreamConfig? = nil,
        configPath: String? = nil,
        dryRun: Bool = false,
        projectDir: String? = nil
    ) {
        self.configOverrides = configOverrides
        self.configPath = configPath
        self.dryRun = dryRun
        self.projectDir = projectDir
    }
}

// MARK: - Manifest Resolution

private func findManifestFiles(_ dir: String) -> [String] {
    let fm = FileManager.default
    var files: [String] = []

    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return files }

    for entry in entries {
        let fullPath = (dir as NSString).appendingPathComponent(entry)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

        if isDir.boolValue {
            files.append(contentsOf: findManifestFiles(fullPath))
        } else if entry.hasSuffix(".json") {
            files.append(fullPath)
        }
    }

    return files
}

private func loadManifestFiles(_ files: [String]) -> [ProviderManifest] {
    var manifests: [ProviderManifest] = []
    let decoder = JSONDecoder()

    for file in files {
        guard let data = FileManager.default.contents(atPath: file),
              let manifest = try? decoder.decode(ProviderManifest.self, from: data),
              !manifest.tools.isEmpty else {
            continue
        }
        manifests.append(manifest)
    }

    return manifests
}

private func resolveManifests(sourcePath: String?) -> [ProviderManifest] {
    let fm = FileManager.default
    let searchPath: String
    if let sourcePath {
        searchPath = (sourcePath as NSString).standardizingPath
    } else {
        searchPath = fm.currentDirectoryPath
    }

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: searchPath, isDirectory: &isDir) else { return [] }

    if !isDir.boolValue {
        // Single file
        if let data = fm.contents(atPath: searchPath),
           let manifest = try? JSONDecoder().decode(ProviderManifest.self, from: data) {
            return [manifest]
        }
        return []
    }

    // Directory scan
    let files = findManifestFiles(searchPath)
    return files.isEmpty ? [] : loadManifestFiles(files)
}

private func extractKnownToolNames(_ manifests: [ProviderManifest]) -> [String] {
    var names: Set<String> = []
    for manifest in manifests {
        for tool in manifest.tools {
            names.insert(tool.name)
        }
    }
    return Array(names)
}

// MARK: - Serialization

private func serializeResult(
    _ result: CompilationResult,
    embedderType: String,
    hints: ToolPriorityHints
) -> Data {
    var output: [String: Any] = [:]

    var selectors: [String: Any] = [:]
    for (key, sel) in result.selectors {
        selectors[key] = [
            "canonical": sel.canonical,
            "parts": sel.parts,
            "arity": sel.arity,
            "vector": sel.vector,
        ] as [String: Any]
    }

    var dispatchTables: [String: Any] = [:]
    for (providerId, table) in result.dispatchTables {
        var methods: [String: Any] = [:]
        for (canonical, imp) in table {
            methods[canonical] = [
                "providerId": imp.providerId,
                "toolName": imp.toolName,
                "transportType": imp.transportType.rawValue,
            ] as [String: Any]
        }
        dispatchTables[providerId] = methods
    }

    let dreamMetadata: [String: Any] = [
        "boosted": hints.boosted,
        "demoted": hints.demoted,
        "excluded": Array(hints.excluded),
        "reasoning": hints.reasoning,
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
    ]

    output["version"] = "0.2.0"
    output["timestamp"] = ISO8601DateFormatter().string(from: Date())
    output["embedding"] = [
        "model": embedderType == "onnx" ? "all-MiniLM-L6-v2" : "hash-based",
        "dimensions": 384,
        "embedderType": embedderType,
    ] as [String: Any]
    output["stats"] = [
        "toolCount": result.toolCount,
        "uniqueSelectorCount": result.uniqueSelectorCount,
        "mergedCount": result.mergedCount,
        "providerCount": result.dispatchTables.count,
        "collisionCount": result.collisions.count,
    ] as [String: Any]
    output["selectors"] = selectors
    output["dispatchTables"] = dispatchTables
    output["dreamMetadata"] = dreamMetadata

    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
}

// MARK: - Main Entry Points

/// Run the dream pipeline: analyze memory + logs, then compile with insights.
///
/// This is the primary API. Also aliased as `dream()`.
public func compileLatest(_ options: CompileLatestOptions = CompileLatestOptions()) async throws -> DreamResult {
    let projectDir = options.projectDir ?? FileManager.default.currentDirectoryPath
    let config = loadDreamConfig(overrides: options.configOverrides, configPath: options.configPath)

    // Step 1: Resolve source manifests
    print("Resolving tool manifests...")
    let manifests = resolveManifests(sourcePath: config.sourcePath)
    let knownTools = extractKnownToolNames(manifests)
    print("  Found \(manifests.count) manifest(s) with \(knownTools.count) tools")

    // Step 2: Read memory files
    print("\nReading memory files...")
    let memoryFiles = readMemoryFiles(config, projectDir: projectDir)
    print("  Found \(memoryFiles.count) memory file(s)")

    // Step 3: Extract tool mentions from memory
    let allMentions = memoryFiles.flatMap { file in
        extractToolMentions(file.content, knownTools: knownTools, source: file.path)
    }
    print("  Extracted \(allMentions.count) tool mention(s)")

    // Step 4: Analyze session logs
    print("\nAnalyzing session logs...")
    let logFiles = discoverLogFiles(config.logDir)
    print("  Found \(logFiles.count) log file(s)")

    let allRecords = logFiles.flatMap { analyzeSessionLog($0) }
    let usageStats = aggregateUsageStats(allRecords)
    print("  Analyzed \(allRecords.count) tool call(s) across \(usageStats.count) unique tool(s)")

    // Step 5: Prioritize tools
    print("\nPrioritizing tools...")
    let hints = prioritizeTools(allMentions, usageStats, knownTools)
    print("  Boosted: \(hints.boosted.count), Demoted: \(hints.demoted.count), Excluded: \(hints.excluded.count)")

    // Step 6: Generate report
    let report = generateReport(hints, usageStats, allMentions)

    let analysis = DreamAnalysis(
        memoryMentions: allMentions,
        usageStats: usageStats,
        priorityHints: hints,
        report: report,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )

    // Dry run -- return analysis only
    if options.dryRun {
        print("\n" + report)
        return DreamResult(
            analysis: analysis,
            artifactPath: nil,
            archivedPath: nil,
            autoPromoted: false
        )
    }

    // Step 7: Archive current artifact before overwriting
    print("\nArchiving current artifact...")
    let archived = archiveCurrentArtifact(projectDir, outputPath: config.outputPath, isAutoGenerated: false)
    if let archived {
        print("  Archived to: \(archived.path)")
    }

    // Step 8: Compile with priority hints
    print("\nCompiling with dream insights...")

    // Filter out excluded tools from manifests
    let filteredManifests: [ProviderManifest] = manifests.map { manifest in
        ProviderManifest(
            id: manifest.id,
            name: manifest.name,
            tools: manifest.tools.filter { !hints.excluded.contains($0.name) },
            transportType: manifest.transportType,
            endpoint: manifest.endpoint,
            version: manifest.version,
            channel: manifest.channel
        )
    }

    let embedder = LocalEmbedder()
    let vectorIndex = MemoryVectorIndex()
    let compiler = ToolCompiler(embedder: embedder, vectorIndex: vectorIndex)
    let result = try await compiler.compile(filteredManifests)

    // Serialize with dream metadata
    let jsonData = serializeResult(result, embedderType: config.embedder.rawValue, hints: hints)
    let outputPath = (projectDir as NSString).appendingPathComponent(config.outputPath)
    let newArtifactPath = outputPath + ".dream-pending.json"

    try jsonData.write(to: URL(fileURLWithPath: newArtifactPath))

    print("  Compiled: \(result.toolCount) tools, \(result.uniqueSelectorCount) selectors")

    // Step 9: Auto-promote if enabled
    var autoPromoted = false
    if config.autoDream {
        promoteArtifact(projectDir, newArtifactPath: newArtifactPath, outputPath: config.outputPath)
        autoPromoted = true
        print("\nAuto-promoted new artifact to: \(config.outputPath)")

        let pruned = pruneOldVersions(projectDir, maxRetained: config.maxRetainedVersions)
        if !pruned.isEmpty {
            print("  Pruned \(pruned.count) old version(s)")
        }
    } else {
        print("\nNew artifact ready at: \(newArtifactPath)")
        print("Run with --auto to replace automatically, or manually copy to overwrite.")
    }

    print("\n" + report)

    return DreamResult(
        analysis: analysis,
        artifactPath: newArtifactPath,
        archivedPath: archived?.path,
        autoPromoted: autoPromoted
    )
}

/// Alias for compileLatest.
public func dream(_ options: CompileLatestOptions = CompileLatestOptions()) async throws -> DreamResult {
    try await compileLatest(options)
}
