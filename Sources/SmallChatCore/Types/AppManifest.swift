/// AppManifest -- describes an App and its UI components.
///
/// Parallel to `ProviderManifest` but for the App/UI layer.
/// `uiResourceUri` carries the HTML content for the app's primary UI entry point:
/// either an inline HTML string (starts with `<`) or a `file://` path.
public struct AppManifest: Sendable, Codable {
    public let id: String
    public let name: String
    public let uiResourceUri: String?
    public let components: [ComponentDefinition]
    public let version: String?
    public let description: String?

    public init(
        id: String,
        name: String,
        uiResourceUri: String? = nil,
        components: [ComponentDefinition] = [],
        version: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.uiResourceUri = uiResourceUri
        self.components = components
        self.version = version
        self.description = description
    }
}

/// A single UI component declared inside an `AppManifest`.
public struct ComponentDefinition: Sendable, Codable {
    public let name: String
    public let description: String
    public let intentText: String?

    public init(name: String, description: String, intentText: String? = nil) {
        self.name = name
        self.description = description
        self.intentText = intentText
    }
}
