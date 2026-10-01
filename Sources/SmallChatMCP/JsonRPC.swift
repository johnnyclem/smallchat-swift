// MARK: - JSON-RPC 2.0 Types for MCP Protocol

import Foundation
import SmallChatCore

// MARK: - Protocol Constants

/// MCP protocol versions the server negotiates, newest first.
///
/// Only versions whose required behavior the server implements: a single
/// Streamable HTTP endpoint answering with `application/json`, sessions
/// (`Mcp-Session-Id`), `MCP-Protocol-Version` header checks, `202` for
/// notifications, Origin validation (`403`), no JSON-RPC batches, and
/// `structuredContent` in tool results. 2025-03-26 (which requires accepting
/// batches) and 2024-11-05 (HTTP+SSE transport) are not claimed.
public let mcpSupportedProtocolVersions: [String] = ["2025-11-25", "2025-06-18"]

/// The newest MCP protocol version this implementation speaks.
public let mcpProtocolVersion: String = mcpSupportedProtocolVersions[0]

/// Negotiate a protocol version the way MCP's `initialize` specifies: a
/// requested version that is supported is echoed; anything else (or nothing)
/// gets the newest supported version, and the client decides whether it can
/// speak it.
public func negotiateMCPProtocolVersion(
    _ requested: String?,
    supported: [String] = mcpSupportedProtocolVersions
) -> String {
    if let requested, supported.contains(requested) { return requested }
    return supported[0]
}

/// Server identification constants.
public let mcpServerName: String = "smallchat"
public let mcpServerVersion: String = SmallChatVersion.current

// MARK: - JSON-RPC Request ID

/// A JSON-RPC 2.0 request ID that can be a string, integer, or null.
public enum JSONRPCId: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSONRPCId must be string, integer, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - JSON-RPC Request

/// A JSON-RPC 2.0 request message.
public struct JSONRPCRequest: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let method: String
    public let params: [String: AnyCodableValue]?

    public init(
        id: JSONRPCId? = nil,
        method: String,
        params: [String: AnyCodableValue]? = nil
    ) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    /// Whether this request is a notification (no id).
    public var isNotification: Bool {
        id == nil
    }
}

// MARK: - JSON-RPC Error

/// A JSON-RPC 2.0 error object.
public struct JSONRPCError: Error, Sendable, Codable {
    public let code: Int
    public let message: String
    public let data: AnyCodableValue?

    public init(code: Int, message: String, data: AnyCodableValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - JSON-RPC Response

/// A JSON-RPC 2.0 response message.
public struct JSONRPCResponse: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let result: AnyCodableValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCId, result: AnyCodableValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCId, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    /// Convenience: create a success response.
    public static func ok(_ id: JSONRPCId, _ result: AnyCodableValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result)
    }

    /// Convenience: create an error response.
    public static func error(_ id: JSONRPCId, code: Int, message: String, data: AnyCodableValue? = nil) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message, data: data))
    }
}

// MARK: - JSON-RPC Notification

/// A JSON-RPC 2.0 notification (no id, no response expected).
public struct JSONRPCNotification: Sendable, Codable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodableValue]?

    public init(method: String, params: [String: AnyCodableValue]? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

// MARK: - MCP Error Codes

/// Standard JSON-RPC and MCP-specific error codes.
public enum MCPErrorCode: Int, Sendable {
    // JSON-RPC standard
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603

    // MCP-specific
    case unsupportedVersion = -32000
    case sessionExpired = -32001
    case capabilityMismatch = -32002
    case alreadyInitialized = -32003
    case notInitialized = -32010
    case sessionClosed = -32011
    case invalidCursor = -32020
    case toolNotFound = -32040
    case insufficientScope = -32041
    case resourceNotFound = -32050
    case promptNotFound = -32060
}

// MARK: - MCP Method

/// All recognized MCP JSON-RPC method strings.
public enum MCPMethod: String, Sendable, CaseIterable {
    case initialize = "initialize"
    case ping = "ping"
    case notificationsInitialized = "notifications/initialized"

    case toolsList = "tools/list"
    case toolsCall = "tools/call"

    case resourcesList = "resources/list"
    case resourcesRead = "resources/read"
    case resourcesTemplatesList = "resources/templates/list"
    case resourcesSubscribe = "resources/subscribe"
    case resourcesUnsubscribe = "resources/unsubscribe"

    case promptsList = "prompts/list"
    case promptsGet = "prompts/get"
}

// MARK: - MCP Capabilities

/// Server capability flags returned during initialization.
public struct MCPCapabilities: Sendable, Codable {
    public var tools: ToolCapability?
    public var resources: ResourceCapability?
    public var prompts: PromptCapability?
    public var logging: [String: AnyCodableValue]?

    public init(
        tools: ToolCapability? = ToolCapability(),
        resources: ResourceCapability? = ResourceCapability(),
        prompts: PromptCapability? = PromptCapability(),
        logging: [String: AnyCodableValue]? = [:]
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
    }

    public struct ToolCapability: Sendable, Codable {
        public var listChanged: Bool

        public init(listChanged: Bool = true) {
            self.listChanged = listChanged
        }
    }

    public struct ResourceCapability: Sendable, Codable {
        public var subscribe: Bool
        public var listChanged: Bool

        public init(subscribe: Bool = true, listChanged: Bool = true) {
            self.subscribe = subscribe
            self.listChanged = listChanged
        }
    }

    public struct PromptCapability: Sendable, Codable {
        public var listChanged: Bool

        public init(listChanged: Bool = true) {
            self.listChanged = listChanged
        }
    }
}

// MARK: - Session Status

/// The lifecycle status of an MCP session.
public enum SessionStatus: String, Sendable, Codable {
    case active
    case closed
}

// MARK: - MCP Client Capabilities

/// Capabilities reported by the client during initialization.
public struct MCPClientCapabilities: Sendable, Codable {
    public var tools: Bool?
    public var resources: Bool?
    public var prompts: Bool?
    public var apps: Bool?
    public var streaming: StreamingCapabilities?

    public init(
        tools: Bool? = nil,
        resources: Bool? = nil,
        prompts: Bool? = nil,
        apps: Bool? = nil,
        streaming: StreamingCapabilities? = nil
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.apps = apps
        self.streaming = streaming
    }

    public struct StreamingCapabilities: Sendable, Codable {
        public var sse: Bool?
        public var stdio: Bool?
        public var tokenDeltas: Bool?

        public init(sse: Bool? = nil, stdio: Bool? = nil, tokenDeltas: Bool? = nil) {
            self.sse = sse
            self.stdio = stdio
            self.tokenDeltas = tokenDeltas
        }
    }
}

// MARK: - SSE Event Kind

/// The kind of event sent over an SSE stream.
public enum SSEEventKind: String, Sendable, Codable {
    case jsonrpc
    case progress
    case toolsListChanged = "tools/list_changed"
    case resourceChanged
    case stream
}

// MARK: - SSE Envelope

/// Wrapper envelope for SSE events.
public struct SSEEnvelope: Sendable, Codable {
    public let sessionId: String
    public let ts: String
    public let seq: Int
    public let kind: SSEEventKind
    public let payload: [String: AnyCodableValue]

    public init(
        sessionId: String,
        ts: String,
        seq: Int,
        kind: SSEEventKind,
        payload: [String: AnyCodableValue]
    ) {
        self.sessionId = sessionId
        self.ts = ts
        self.seq = seq
        self.kind = kind
        self.payload = payload
    }
}

// MARK: - Validation Helpers

/// Validate a raw decoded JSON-RPC request envelope.
public func validateRPCEnvelope(_ dict: [String: AnyCodableValue]) -> Result<JSONRPCRequest, JSONRPCError> {
    guard case .string(let version) = dict["jsonrpc"], version == "2.0" else {
        return .failure(JSONRPCError(
            code: MCPErrorCode.invalidRequest.rawValue,
            message: "Invalid Request: jsonrpc must be \"2.0\""
        ))
    }

    guard case .string(let method) = dict["method"] else {
        return .failure(JSONRPCError(
            code: MCPErrorCode.invalidRequest.rawValue,
            message: "Invalid Request: method must be a string"
        ))
    }

    let id: JSONRPCId?
    if let idValue = dict["id"] {
        switch idValue {
        case .string(let s): id = .string(s)
        case .int(let i): id = .int(i)
        // `1.0` (or 1e3) reads as a double, as JSON.parse would; its value is an integer.
        case .double(let d) where d.rounded() == d && abs(d) <= 9_007_199_254_740_992: id = .int(Int(d))
        case .null: id = .null
        default:
            return .failure(JSONRPCError(
                code: MCPErrorCode.invalidRequest.rawValue,
                message: "Invalid Request: id must be string, integer, or null"
            ))
        }
    } else {
        id = nil
    }

    var params: [String: AnyCodableValue]?
    if let paramsValue = dict["params"] {
        guard case .dict(let d) = paramsValue else {
            return .failure(JSONRPCError(
                code: MCPErrorCode.invalidParams.rawValue,
                message: "Invalid params: params must be an object"
            ))
        }
        params = d
    }

    return .success(JSONRPCRequest(id: id, method: method, params: params))
}
