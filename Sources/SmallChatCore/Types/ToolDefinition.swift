public struct ToolDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchemaType
    public let providerId: String
    public let transportType: TransportType
    public let compilerHints: CompilerHint?
    /// Human-readable title (MCP `title`).
    public let title: String?
    /// JSON Schema of the tool's structured output (MCP `outputSchema`).
    public let outputSchema: JSONSchemaType?
    /// MCP tool annotations declared by the upstream server.
    public let annotations: ToolAnnotations?
    /// MCP Apps `ui://` resource the tool renders into.
    public let uiResourceUri: String?
    /// MCP Apps visibility (`model`, `app`).
    public let uiVisibility: [String]?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchemaType,
        providerId: String,
        transportType: TransportType,
        compilerHints: CompilerHint? = nil,
        title: String? = nil,
        outputSchema: JSONSchemaType? = nil,
        annotations: ToolAnnotations? = nil,
        uiResourceUri: String? = nil,
        uiVisibility: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.providerId = providerId
        self.transportType = transportType
        self.compilerHints = compilerHints
        self.title = title
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.uiResourceUri = uiResourceUri
        self.uiVisibility = uiVisibility
    }
}
