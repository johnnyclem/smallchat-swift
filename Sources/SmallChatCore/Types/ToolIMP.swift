public protocol ToolIMP: AnyObject, Sendable {
    var providerId: String { get }
    var toolName: String { get }
    var transportType: TransportType { get }
    var schema: ToolSchema? { get }
    /// MCP annotations the upstream tool declares (nil: none). The dispatch
    /// policy treats destructive tools differently (`isDestructive`).
    var annotations: ToolAnnotations? { get }

    func loadSchema() async throws -> ToolSchema
    func execute(args: [String: any Sendable]) async throws -> ToolResult
}

extension ToolIMP {
    public var annotations: ToolAnnotations? { nil }

    /// Canonical tool id: `<providerId>/<toolName>`.
    public var toolId: String { "\(providerId)/\(toolName)" }
}

public protocol StreamableIMP: ToolIMP {
    func executeStream(args: [String: any Sendable]) -> AsyncThrowingStream<ToolResult, Error>
}

public protocol InferenceIMP: StreamableIMP {
    func executeInference(args: [String: any Sendable]) -> AsyncThrowingStream<InferenceDelta, Error>
}
