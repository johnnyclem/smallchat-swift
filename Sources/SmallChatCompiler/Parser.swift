import SmallChatCore

/// A parsed tool definition ready for compilation
public struct ParsedTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchemaType
    public let providerId: String
    public let transportType: TransportType
    public let arguments: [ArgumentSpec]
    public let compilerHints: CompilerHint?
    public let providerHints: ProviderCompilerHints?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchemaType,
        providerId: String,
        transportType: TransportType,
        arguments: [ArgumentSpec],
        compilerHints: CompilerHint? = nil,
        providerHints: ProviderCompilerHints? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.providerId = providerId
        self.transportType = transportType
        self.arguments = arguments
        self.compilerHints = compilerHints
        self.providerHints = providerHints
    }

    /// Text fed to the embedder. Folds provider + tool compiler hints
    /// into a single string so that semantic dispatch can match against
    /// vendor-supplied selector hints, aliases, and provider context.
    public var embeddingText: String {
        var parts: [String] = ["\(name): \(description)"]
        if let hint = compilerHints?.selectorHint, !hint.isEmpty {
            parts.append(hint)
        }
        if let aliases = compilerHints?.aliases, !aliases.isEmpty {
            parts.append(aliases.joined(separator: " | "))
        }
        if let context = providerHints?.semanticContext, !context.isEmpty {
            parts.append(context)
        }
        return parts.joined(separator: "\n")
    }
}

/// Parse an MCP-format provider manifest into individual tool definitions
public func parseMCPManifest(_ manifest: ProviderManifest) -> [ParsedTool] {
    manifest.tools.compactMap { tool in
        // Honor explicit exclusion from per-tool compiler hints.
        if tool.compilerHints?.exclude == true { return nil }

        // Extract argument specs from inputSchema properties
        var arguments: [ArgumentSpec] = []
        if let props = tool.inputSchema.properties {
            let requiredSet = Set(tool.inputSchema.required ?? [])
            for (name, schema) in props.sorted(by: { $0.key < $1.key }) {
                arguments.append(ArgumentSpec(
                    name: name,
                    type: schema,
                    description: schema.description ?? "",
                    enumValues: schema.enumValues,
                    defaultValue: schema.defaultValue,
                    required: requiredSet.contains(name)
                ))
            }
        }

        return ParsedTool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
            providerId: manifest.id,
            transportType: manifest.transportType,
            arguments: arguments,
            compilerHints: tool.compilerHints,
            providerHints: manifest.compilerHints
        )
    }
}

/// Parse an OpenAPI spec (simplified -- takes tool definitions directly)
public func parseOpenAPISpec(_ tools: [ToolDefinition]) -> [ParsedTool] {
    tools.compactMap { tool in
        if tool.compilerHints?.exclude == true { return nil }

        var arguments: [ArgumentSpec] = []
        if let props = tool.inputSchema.properties {
            let requiredSet = Set(tool.inputSchema.required ?? [])
            for (name, schema) in props.sorted(by: { $0.key < $1.key }) {
                arguments.append(ArgumentSpec(
                    name: name,
                    type: schema,
                    description: schema.description ?? "",
                    enumValues: nil,
                    defaultValue: nil,
                    required: requiredSet.contains(name)
                ))
            }
        }
        return ParsedTool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
            providerId: tool.providerId,
            transportType: tool.transportType,
            arguments: arguments,
            compilerHints: tool.compilerHints
        )
    }
}

/// Parse raw schema format
public func parseRawSchema(_ tools: [ToolDefinition]) -> [ParsedTool] {
    parseOpenAPISpec(tools)
}
