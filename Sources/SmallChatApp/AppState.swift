import Foundation
import SmallChat

// MARK: - Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case compiler = "Compiler"
    case server = "Server"
    case manifest = "Manifest"
    case inspector = "Inspector"
    case resolver = "Resolver"
    case discovery = "Discovery"
    case doctor = "Doctor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .compiler: return "hammer"
        case .server: return "server.rack"
        case .manifest: return "doc.text"
        case .inspector: return "magnifyingglass"
        case .resolver: return "arrow.triangle.branch"
        case .discovery: return "antenna.radiowaves.left.and.right"
        case .doctor: return "stethoscope"
        }
    }
}

// MARK: - Diagnostic Check

struct DiagnosticCheck: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let passed: Bool
}

// MARK: - Resolved Match (for resolver view)

struct ResolvedMatch: Identifiable {
    let id = UUID()
    let selector: String
    let confidence: Double
    let provider: String
}

// MARK: - Discovered Config (for discovery view)

struct DiscoveredConfigItem: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    var selected: Bool = true
}

// MARK: - App State

@MainActor @Observable
final class AppState {
    // Navigation
    var selectedSection: AppSection = .compiler

    // MARK: - Compiler State
    var compilerSourcePath: String = ""
    var compilerOutputPath: String = "tools.toolkit.json"
    var collisionThreshold: Double = 0.89
    var deduplicationThreshold: Double = 0.95
    var generateSemanticOverloads: Bool = false
    var compilerLog: [String] = []
    var isCompiling: Bool = false
    var lastToolCount: Int = 0
    var lastSelectorCount: Int = 0
    var lastMergedCount: Int = 0
    var lastProviderCount: Int = 0
    var lastCollisionCount: Int = 0

    // MARK: - Server State
    var serverPort: Int = 3001
    var serverHost: String = "127.0.0.1"
    var serverSourcePath: String = ""
    var serverDbPath: String = "smallchat.db"
    var serverEnableAuth: Bool = false
    var serverEnableRateLimit: Bool = false
    var serverRateLimitRPM: Int = 600
    var serverEnableAudit: Bool = false
    var serverSessionTTLHours: Double = 24
    var serverRunning: Bool = false
    var serverLog: [String] = []
    var serverMetrics: [String: String] = [:]
    var mcpServer: MCPServer?

    // MARK: - Manifest Editor State
    var manifestPath: String = ""
    var manifestName: String = ""
    var manifestVersion: String = "0.1.0"
    var manifestDescription: String = ""
    var manifestDependencies: [String: String] = [:]
    var manifestDirectories: [String] = []
    var manifestEmbedder: String = "local"
    var manifestDeduplicationThreshold: Double = 0.95
    var manifestCollisionThreshold: Double = 0.89
    var manifestGenerateOverloads: Bool = false
    var manifestOutputPath: String = "tools.toolkit.json"
    var manifestOutputFormat: String = "json"
    var manifestDbPath: String = ""

    // MARK: - Inspector State
    var inspectorFilePath: String = ""
    var inspectorVersion: String = ""
    var inspectorTimestamp: String = ""
    var inspectorToolCount: Int = 0
    var inspectorSelectorCount: Int = 0
    var inspectorProviderCount: Int = 0
    var inspectorCollisionCount: Int = 0
    var inspectorMergedCount: Int = 0
    var inspectorEmbeddingModel: String = ""
    var inspectorEmbeddingDimensions: Int = 0
    var inspectorSelectors: [(canonical: String, arity: Int)] = []
    var inspectorProviders: [(id: String, tools: [String])] = []
    var inspectorCollisions: [(selectorA: String, selectorB: String, similarity: Double, hint: String)] = []

    // MARK: - Resolver State
    var resolverArtifactPath: String = ""
    var resolverIntent: String = ""
    var resolverTopK: Int = 5
    var resolverThreshold: Float = 0.5
    var resolverMatches: [ResolvedMatch] = []
    var resolverLog: [String] = []
    var isResolving: Bool = false

    // MARK: - Discovery State
    var discoveredConfigs: [DiscoveredConfigItem] = []
    var isScanning: Bool = false
    var discoveryLog: [String] = []

    // MARK: - Doctor State
    var diagnosticResults: [DiagnosticCheck] = []
    var isRunningDiagnostics: Bool = false
}
