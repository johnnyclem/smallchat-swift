// MARK: - MCPClientTransport — MCP client-side transport

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SmallChatCore

// MARK: - Transport Options

/// Configuration for an MCP client transport.
public struct MCPTransportOptions: Sendable {
    public let transportType: TransportType
    public let endpoint: String?
    public let headers: [String: String]

    public init(
        transportType: TransportType,
        endpoint: String? = nil,
        headers: [String: String] = [:]
    ) {
        self.transportType = transportType
        self.endpoint = endpoint
        self.headers = headers
    }
}

// MARK: - MCPClientTransport

/// Client-side transport for connecting to MCP servers.
///
/// Supports multiple transport types:
/// - MCP: Streamable HTTP. Requests are POSTed to the endpoint with
///   `Accept: application/json, text/event-stream`; a response is read from
///   either a JSON body or an SSE stream. The session id from `initialize`'s
///   `Mcp-Session-Id` header and the negotiated `MCP-Protocol-Version` are
///   sent on later requests, and a session the server dropped (404) is
///   re-established once.
/// - REST: Standard HTTP API calls
/// - Local / gRPC: not supported; calls fail
public actor MCPClientTransport {

    /// Versions this client accepts in `initialize`'s answer.
    public static let acceptedProtocolVersions: Set<String> = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    private let endpoint: String?
    private let transportType: TransportType
    private let headers: [String: String]
    private var requestCounter: Int = 0
    private var sessionId: String?
    private var protocolVersion: String?
    private var initialized = false

    public init(options: MCPTransportOptions) {
        self.endpoint = options.endpoint
        self.transportType = options.transportType
        self.headers = options.headers
    }

    // MARK: - Session Management

    /// The current session ID (set after initialize).
    public var currentSessionId: String? { sessionId }

    /// The protocol version the server agreed to (set after initialize).
    public var negotiatedProtocolVersion: String? { protocolVersion }

    /// Set the session ID (typically from an initialize response).
    public func setSessionId(_ id: String) {
        sessionId = id
    }

    // MARK: - JSON-RPC Requests

    /// Send a JSON-RPC request and return the response.
    public func sendRequest(
        method: String,
        params: [String: AnyCodableValue]? = nil
    ) async throws -> JSONRPCResponse {
        requestCounter += 1
        let id = JSONRPCId.int(requestCounter)

        let request = JSONRPCRequest(id: id, method: method, params: params)
        return try await executeJSONRPC(request)
    }

    /// Send a notification (no response expected).
    public func sendNotification(
        method: String,
        params: [String: AnyCodableValue]? = nil
    ) async throws {
        let notification = JSONRPCNotification(method: method, params: params)
        try await sendJSONRPCNotification(notification)
    }

    // MARK: - MCP Protocol Operations

    /// Initialize the connection to an MCP server: negotiate the protocol
    /// version, keep the session id, and send `notifications/initialized`.
    public func initialize(
        clientName: String = "smallchat",
        clientVersion: String = SmallChatVersion.current
    ) async throws -> JSONRPCResponse {
        sessionId = nil
        protocolVersion = nil
        initialized = false
        let response = try await sendRequest(method: MCPMethod.initialize.rawValue, params: [
            "protocolVersion": .string(mcpProtocolVersion),
            "capabilities": .dict([:]),
            "clientInfo": .dict([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
        if let error = response.error {
            throw MCPClientError.initializeFailed(error.message)
        }

        // Session id: the Mcp-Session-Id header (read by executeJSONRPC);
        // smallchat servers before 1.0 put it in the result instead.
        if sessionId == nil, case .dict(let result) = response.result,
           case .string(let sid) = result["sessionId"] {
            sessionId = sid
        }
        guard case .dict(let result) = response.result,
              case .string(let version) = result["protocolVersion"],
              Self.acceptedProtocolVersions.contains(version) else {
            throw MCPClientError.unsupportedProtocolVersion
        }
        protocolVersion = version

        // Send initialized notification
        try await sendNotification(method: MCPMethod.notificationsInitialized.rawValue)
        initialized = true

        return response
    }

    private func ensureInitialized() async throws {
        if !initialized {
            _ = try await initialize()
        }
    }

    /// List available tools from the server.
    public func listTools(cursor: String? = nil) async throws -> JSONRPCResponse {
        var params: [String: AnyCodableValue] = [:]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return try await sendRequest(method: MCPMethod.toolsList.rawValue, params: params)
    }

    /// Call a tool on the server.
    public func callTool(
        name: String,
        arguments: [String: AnyCodableValue] = [:]
    ) async throws -> JSONRPCResponse {
        try await sendRequest(method: MCPMethod.toolsCall.rawValue, params: [
            "name": .string(name),
            "arguments": .dict(arguments),
        ])
    }

    /// List available resources.
    public func listResources(cursor: String? = nil) async throws -> JSONRPCResponse {
        var params: [String: AnyCodableValue] = [:]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return try await sendRequest(method: MCPMethod.resourcesList.rawValue, params: params)
    }

    /// Read a resource by URI.
    public func readResource(uri: String) async throws -> JSONRPCResponse {
        try await sendRequest(method: MCPMethod.resourcesRead.rawValue, params: [
            "uri": .string(uri),
        ])
    }

    /// List available prompts.
    public func listPrompts(cursor: String? = nil) async throws -> JSONRPCResponse {
        var params: [String: AnyCodableValue] = [:]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return try await sendRequest(method: MCPMethod.promptsList.rawValue, params: params)
    }

    /// Get a prompt by name with optional arguments.
    public func getPrompt(
        name: String,
        arguments: [String: String]? = nil
    ) async throws -> JSONRPCResponse {
        var params: [String: AnyCodableValue] = ["name": .string(name)]
        if let arguments {
            var argsDict: [String: AnyCodableValue] = [:]
            for (k, v) in arguments { argsDict[k] = .string(v) }
            params["arguments"] = .dict(argsDict)
        }
        return try await sendRequest(method: MCPMethod.promptsGet.rawValue, params: params)
    }

    /// Ping the server.
    public func ping() async throws -> JSONRPCResponse {
        try await sendRequest(method: MCPMethod.ping.rawValue)
    }

    /// End the session (HTTP `DELETE` on the endpoint with the session id).
    public func terminateSession() async throws {
        guard let endpoint, let url = URL(string: endpoint), let sid = sessionId else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        _ = try await URLSession.shared.data(for: request)
        sessionId = nil
        initialized = false
    }

    // MARK: - Tool Execution

    /// Execute a tool call via the appropriate transport.
    public func execute(
        toolName: String,
        args: [String: AnyCodableValue]
    ) async throws -> ToolResult {
        switch transportType {
        case .mcp:
            return try await executeMCP(toolName: toolName, args: args)
        case .rest:
            return try await executeREST(toolName: toolName, args: args)
        case .local:
            return ToolResult(
                content: nil as (any Sendable)?,
                isError: true,
                metadata: ["error": "Local transport requires registered handler" as any Sendable]
            )
        case .grpc:
            return ToolResult(
                content: nil as (any Sendable)?,
                isError: true,
                metadata: ["error": "gRPC transport not yet implemented" as any Sendable]
            )
        }
    }

    /// Stream tool execution results.
    public func executeStream(
        toolName: String,
        args: [String: AnyCodableValue]
    ) -> AsyncThrowingStream<ToolResult, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let result = try await self.execute(toolName: toolName, args: args)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Transport Methods

    /// Call an upstream MCP tool. The upstream `CallToolResult` is the result's
    /// content (flagged with `mcpCallToolResultMetadataKey`), so a smallchat
    /// MCP server passes it through unchanged.
    private func executeMCP(toolName: String, args: [String: AnyCodableValue]) async throws -> ToolResult {
        try await ensureInitialized()
        var response: JSONRPCResponse
        do {
            response = try await callTool(name: toolName, arguments: args)
        } catch MCPClientError.sessionExpired {
            // The server dropped the session: start a new one, once.
            _ = try await initialize()
            response = try await callTool(name: toolName, arguments: args)
        }

        if let error = response.error {
            return ToolResult(
                content: nil as (any Sendable)?,
                isError: true,
                metadata: [
                    "error": error.message as any Sendable,
                    "code": error.code as any Sendable,
                ]
            )
        }

        guard case .dict(var result) = response.result else {
            throw MCPClientError.invalidResponse("tools/call result is not an object")
        }
        let isError: Bool
        if case .bool(let e) = result["isError"] { isError = e } else { isError = false }
        if result["content"] == nil { result["content"] = .array([]) }

        return ToolResult(
            content: AnyCodableValue.dict(result),
            isError: isError,
            metadata: [mcpCallToolResultMetadataKey: true as any Sendable]
        )
    }

    private func executeREST(toolName: String, args: [String: AnyCodableValue]) async throws -> ToolResult {
        guard let endpoint else {
            return ToolResult(
                content: nil as (any Sendable)?,
                isError: true,
                metadata: ["error": "No REST endpoint configured" as any Sendable]
            )
        }

        let urlString = endpoint.hasSuffix("/") ? "\(endpoint)\(toolName)" : "\(endpoint)/\(toolName)"
        guard let url = URL(string: urlString) else {
            return ToolResult(
                content: nil as (any Sendable)?,
                isError: true,
                metadata: ["error": "Invalid URL: \(urlString)" as any Sendable]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let bodyData = try JSONEncoder().encode(args)
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        if let decoded = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
            return ToolResult(
                content: decoded as (any Sendable)?,
                isError: statusCode >= 400,
                metadata: ["statusCode": statusCode as any Sendable]
            )
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return ToolResult(
            content: text as (any Sendable)?,
            isError: statusCode >= 400,
            metadata: ["statusCode": statusCode as any Sendable]
        )
    }

    // MARK: - JSON-RPC Transport

    private func executeJSONRPC(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let endpoint else {
            return JSONRPCResponse.error(
                request.id ?? .null,
                code: MCPErrorCode.internalError.rawValue,
                message: "No endpoint configured"
            )
        }

        guard let url = URL(string: endpoint) else {
            return JSONRPCResponse.error(
                request.id ?? .null,
                code: MCPErrorCode.internalError.rawValue,
                message: "Invalid endpoint URL"
            )
        }

        let urlRequest = try buildPost(url: url, body: JSONEncoder().encode(request))
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 404, sessionId != nil, request.method != MCPMethod.initialize.rawValue {
            sessionId = nil
            initialized = false
            throw MCPClientError.sessionExpired
        }
        if request.method == MCPMethod.initialize.rawValue,
           let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionId = sid
        }

        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return try Self.responseFromEventStream(data, id: request.id)
        }
        do {
            return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        } catch {
            throw MCPClientError.invalidResponse("HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private func sendJSONRPCNotification(_ notification: JSONRPCNotification) async throws {
        guard let endpoint, let url = URL(string: endpoint) else { return }
        let urlRequest = try buildPost(url: url, body: JSONEncoder().encode(notification))
        // The server answers 202 Accepted with no body.
        _ = try await URLSession.shared.data(for: urlRequest)
    }

    private func buildPost(url: URL, body: Data) throws -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let sid = sessionId {
            urlRequest.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            urlRequest.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        urlRequest.httpBody = body
        return urlRequest
    }

    /// The JSON-RPC response with `id` in an SSE body (other events, such as
    /// progress notifications, are skipped).
    static func responseFromEventStream(_ data: Data, id: JSONRPCId?) throws -> JSONRPCResponse {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let payload = event
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { line -> Substring in
                    let rest = line.dropFirst(5)
                    return rest.first == " " ? rest.dropFirst() : rest
                }
                .joined(separator: "\n")
            guard !payload.isEmpty,
                  let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: Data(payload.utf8)),
                  id == nil || response.id == id else { continue }
            return response
        }
        throw MCPClientError.invalidResponse("no JSON-RPC response in the event stream")
    }
}

/// Errors from `MCPClientTransport`.
public enum MCPClientError: Error, Sendable, CustomStringConvertible {
    case initializeFailed(String)
    case unsupportedProtocolVersion
    case sessionExpired
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .initializeFailed(let message): return "MCP initialize failed: \(message)"
        case .unsupportedProtocolVersion: return "MCP server answered initialize with an unsupported protocol version"
        case .sessionExpired: return "MCP session expired"
        case .invalidResponse(let message): return "Invalid MCP response: \(message)"
        }
    }
}

// MARK: - Transport Registry

/// Registry for MCP client transport instances.
public actor MCPTransportRegistry {

    private var transports: [String: MCPClientTransport] = [:]

    public init() {}

    /// Get or create a transport for a provider.
    public func getTransport(providerId: String, options: MCPTransportOptions) -> MCPClientTransport {
        let key = "\(providerId):\(options.transportType.rawValue):\(options.endpoint ?? "local")"
        if let existing = transports[key] {
            return existing
        }
        let transport = MCPClientTransport(options: options)
        transports[key] = transport
        return transport
    }

    /// Clear all cached transports.
    public func clearAll() {
        transports.removeAll()
    }
}
