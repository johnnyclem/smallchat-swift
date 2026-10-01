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
    /// MCP annotations of the upstream tool.
    public let annotations: ToolAnnotations?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchemaType,
        providerId: String,
        transportType: TransportType,
        arguments: [ArgumentSpec],
        compilerHints: CompilerHint? = nil,
        providerHints: ProviderCompilerHints? = nil,
        annotations: ToolAnnotations? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.providerId = providerId
        self.transportType = transportType
        self.arguments = arguments
        self.compilerHints = compilerHints
        self.providerHints = providerHints
        self.annotations = annotations
    }

    /// The selector hint in effect: the tool's own, else its provider's
    /// (`semanticContext`, @smallchat/core's provider `selectorHint`).
    public var selectorHint: String? {
        if let hint = compilerHints?.selectorHint, !hint.isEmpty { return hint }
        if let context = providerHints?.semanticContext, !context.isEmpty { return context }
        return nil
    }

    /// The text the tool's primary selector embeds: `<name>: <description>`,
    /// plus the selector hint when there is one (@smallchat/core's
    /// `toolEmbeddingText`). Aliases are not folded in: each alias embeds
    /// on its own, as its own selector.
    public var embeddingText: String {
        toolEmbeddingText(name: name, description: description, selectorHint: selectorHint)
    }
}

/// `<name>: <description>`, plus ` <selectorHint>` when there is one.
public func toolEmbeddingText(name: String, description: String, selectorHint: String?) -> String {
    if let selectorHint, !selectorHint.isEmpty { return "\(name): \(description) \(selectorHint)" }
    return "\(name): \(description)"
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
            providerHints: manifest.compilerHints,
            annotations: tool.annotations
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
            compilerHints: tool.compilerHints,
            annotations: tool.annotations
        )
    }
}

/// Parse raw schema format
public func parseRawSchema(_ tools: [ToolDefinition]) -> [ParsedTool] {
    parseOpenAPISpec(tools)
}
