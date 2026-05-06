/// AppArtifact -- the serialized output of `AppCompiler.compile(_:)`.
///
/// Stored in `CompilationResult.appArtifact`. Contains the per-app dispatch
/// tables and the embedded HTML blobs served under `ui://` URIs.
public struct AppArtifact: Sendable, Codable {
    /// Maps app ID to its serialized dispatch-table data.
    public var appClasses: [String: AppClassData]
    /// Maps `"ui://appId/index.html"` → raw HTML string.
    public var embeddedHTML: [String: String]
    /// Maps component canonical selector → `ui://` URI.
    public var uriMap: [String: String]
    public var appCount: Int

    public init(
        appClasses: [String: AppClassData] = [:],
        embeddedHTML: [String: String] = [:],
        uriMap: [String: String] = [:],
        appCount: Int = 0
    ) {
        self.appClasses = appClasses
        self.embeddedHTML = embeddedHTML
        self.uriMap = uriMap
        self.appCount = appCount
    }
}

/// Serializable form of an `AppClass`.
public struct AppClassData: Sendable, Codable {
    public let appId: String
    public let name: String
    public let uiResourceUri: String?
    public let componentSelectors: [String]

    public init(
        appId: String,
        name: String,
        uiResourceUri: String? = nil,
        componentSelectors: [String] = []
    ) {
        self.appId = appId
        self.name = name
        self.uiResourceUri = uiResourceUri
        self.componentSelectors = componentSelectors
    }
}
