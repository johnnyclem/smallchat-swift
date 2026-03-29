import Foundation

/// Dream configuration -- controls how compileLatest() behaves.
public struct DreamConfig: Sendable, Codable {
    /// Enable auto-dream (auto-replace artifact when dream runs).
    public var autoDream: Bool
    /// Additional paths to memory files (standard Claude locations always checked).
    public var memoryPaths: [String]
    /// Path to Claude projects log directory (empty = auto-detect).
    public var logDir: String
    /// How many previous artifact versions to retain.
    public var maxRetainedVersions: Int
    /// Output path for the compiled artifact.
    public var outputPath: String
    /// Source manifest path/directory (same as compile --source).
    public var sourcePath: String?
    /// Embedder type for compilation.
    public var embedder: EmbedderType

    public init(
        autoDream: Bool = false,
        memoryPaths: [String] = [],
        logDir: String = "",
        maxRetainedVersions: Int = 5,
        outputPath: String = "tools.toolkit.json",
        sourcePath: String? = nil,
        embedder: EmbedderType = .local
    ) {
        self.autoDream = autoDream
        self.memoryPaths = memoryPaths
        self.logDir = logDir
        self.maxRetainedVersions = maxRetainedVersions
        self.outputPath = outputPath
        self.sourcePath = sourcePath
        self.embedder = embedder
    }

    public enum EmbedderType: String, Sendable, Codable {
        case local
        case onnx
    }
}

/// Default dream configuration.
public let defaultDreamConfig = DreamConfig()

private let configFilename = "smallchat.dream.json"

/// Load dream config from disk, merging with defaults and any overrides.
public func loadDreamConfig(
    overrides: DreamConfig? = nil,
    configPath: String? = nil
) -> DreamConfig {
    let filePath = configPath ?? (FileManager.default.currentDirectoryPath + "/" + configFilename)
    var fileConfig: DreamConfig?

    if FileManager.default.fileExists(atPath: filePath) {
        if let data = FileManager.default.contents(atPath: filePath) {
            fileConfig = try? JSONDecoder().decode(DreamConfig.self, from: data)
        }
    }

    // Merge: defaults <- file config <- overrides
    var result = defaultDreamConfig
    if let file = fileConfig {
        result.autoDream = file.autoDream
        if !file.memoryPaths.isEmpty { result.memoryPaths = file.memoryPaths }
        if !file.logDir.isEmpty { result.logDir = file.logDir }
        result.maxRetainedVersions = file.maxRetainedVersions
        result.outputPath = file.outputPath
        result.sourcePath = file.sourcePath
        result.embedder = file.embedder
    }
    if let overrides {
        result.autoDream = overrides.autoDream
        if !overrides.memoryPaths.isEmpty { result.memoryPaths = overrides.memoryPaths }
        if !overrides.logDir.isEmpty { result.logDir = overrides.logDir }
        result.maxRetainedVersions = overrides.maxRetainedVersions
        if overrides.outputPath != defaultDreamConfig.outputPath { result.outputPath = overrides.outputPath }
        if overrides.sourcePath != nil { result.sourcePath = overrides.sourcePath }
        result.embedder = overrides.embedder
    }
    return result
}

/// Save dream config to disk.
public func saveDreamConfig(_ config: DreamConfig, configPath: String? = nil) throws {
    let filePath = configPath ?? (FileManager.default.currentDirectoryPath + "/" + configFilename)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try data.write(to: URL(fileURLWithPath: filePath))
}
