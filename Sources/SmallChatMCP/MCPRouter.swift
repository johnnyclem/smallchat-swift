// MARK: - MCPRouter — JSON-RPC 2.0 dispatcher for MCP methods

import Foundation
import SmallChatCore
import SmallChatRuntime

// MARK: - Router Options

/// Configuration options for the MCP router.
public struct RouterOptions: Sendable {
    public let serverName: String
    public let serverVersion: String
    public let sessionTTLMs: Int
    /// How tools are named in `tools/list` and `tools/call`.
    public let toolNaming: MCPToolNaming
    /// Optional `instructions` returned from `initialize`.
    public let instructions: String?

    public init(
        serverName: String = "smallchat",
        serverVersion: String = SmallChatVersion.current,
        sessionTTLMs: Int = 86_400_000, // 24 hours
        toolNaming: MCPToolNaming = .aggregate,
        instructions: String? = nil
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.sessionTTLMs = sessionTTLMs
        self.toolNaming = toolNaming
        self.instructions = instructions
    }
}

// MARK: - MCPRouter Actor

/// Routes JSON-RPC 2.0 requests to appropriate MCP handlers.
///
/// Maps method strings to handler functions for initialize, ping, tools/list,
/// tools/call, resources/list, resources/read, resources/templates/list,
/// prompts/list and prompts/get. Returns nil for notifications (requests
/// without an id).
///
/// `tools/call` runs exactly the named tool through the wired
/// `MCPToolExecutor`; nothing is resolved fuzzily. Without an executor the
/// call is a JSON-RPC error, never a placeholder success. Semantic dispatch
/// is only available through the explicit `smallchat_dispatch` meta-tool,
/// and only when a `MCPSemanticDispatchHandler` is wired.
public actor MCPRouter {

    private let sessionStore: SessionStore
    private let resourceRegistry: ResourceRegistry
    private let promptRegistry: PromptRegistry
    private let opts: RouterOptions
    private var catalog: MCPToolCatalog?
    private var toolExecutor: MCPToolExecutor?
    private var semanticDispatch: MCPSemanticDispatchHandler?

    public init(
        sessionStore: SessionStore,
        resourceRegistry: ResourceRegistry,
        promptRegistry: PromptRegistry,
        options: RouterOptions = RouterOptions()
    ) {
        self.sessionStore = sessionStore
        self.resourceRegistry = resourceRegistry
        self.promptRegistry = promptRegistry
        self.opts = options
    }

    /// Set the artifact whose tools `tools/list` serves.
    public func setArtifact(_ artifact: SerializedArtifact) {
        self.catalog = MCPToolCatalog(artifact: artifact, naming: opts.toolNaming)
    }

    /// The tools currently served (nil before `setArtifact`).
    public var toolCatalog: MCPToolCatalog? { catalog }

    /// Wire the executor that runs a listed tool for `tools/call`.
    public func setToolExecutor(_ executor: @escaping MCPToolExecutor) {
        self.toolExecutor = executor
    }

    /// Wire semantic dispatch and list the `smallchat_dispatch` meta-tool.
    ///
    /// The handler's `TieredDispatchResult` maps to a `CallToolResult`:
    /// `.dispatched` carries the tool's result, `.decomposed` lists sub-intents,
    /// `.refinement` asks for a clearer intent (nothing ran), and
    /// `.strictAmbiguityError` is `isError: true`.
    public func setSemanticDispatchHandler(_ handler: @escaping MCPSemanticDispatchHandler) {
        self.semanticDispatch = handler
    }

    // MARK: - Main Dispatch

    /// Handle a parsed JSON-RPC request. Returns nil for notifications.
    public func handle(
        request: JSONRPCRequest,
        sessionId: String?
    ) async -> JSONRPCResponse? {
        // Notifications (no id) -- process and return nil
        guard let id = request.id else {
            return nil
        }

        let params = request.params ?? [:]

        switch request.method {
        case MCPMethod.initialize.rawValue:
            return await initialize(request: request).response
        case MCPMethod.ping.rawValue:
            return .ok(id, .dict([:]))
        case MCPMethod.notificationsInitialized.rawValue:
            return .ok(id, .dict([:]))
        case MCPMethod.toolsList.rawValue:
            return handleToolsList(id: id, params: params)
        case MCPMethod.toolsCall.rawValue:
            return await handleToolsCall(id: id, params: params)
        case MCPMethod.resourcesList.rawValue:
            return await handleResourcesList(id: id, params: params, sessionId: sessionId)
        case MCPMethod.resourcesRead.rawValue:
            return await handleResourcesRead(id: id, params: params, sessionId: sessionId)
        case MCPMethod.resourcesTemplatesList.rawValue:
            return await handleResourcesTemplatesList(id: id, sessionId: sessionId)
        case MCPMethod.promptsList.rawValue:
            return await handlePromptsList(id: id, params: params, sessionId: sessionId)
        case MCPMethod.promptsGet.rawValue:
            return await handlePromptsGet(id: id, params: params, sessionId: sessionId)
        default:
            return .error(id, code: MCPErrorCode.methodNotFound.rawValue,
                          message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Initialize

    /// Handle `initialize`: negotiate the protocol version and open a session.
    /// Returns the response and the new session (nil on failure); the HTTP
    /// layer sends the session id as the `Mcp-Session-Id` header.
    public func initialize(request: JSONRPCRequest) async -> (response: JSONRPCResponse, session: MCPSession?) {
        let id = request.id ?? .null
        let params = request.params ?? [:]

        // Extract client info
        var clientInfo: [String: String] = [:]
        if case .dict(let info) = params["clientInfo"] {
            for key in ["name", "version"] {
                if case .string(let value) = info[key] { clientInfo[key] = value }
            }
        }

        var requested: String?
        if case .string(let v) = params["protocolVersion"] { requested = v }
        let version = negotiateMCPProtocolVersion(requested)

        do {
            let session = try await sessionStore.create(protocolVersion: version, clientInfo: clientInfo)

            // Only what the server implements: no list-changed notifications,
            // no resource subscriptions, no logging.
            var result: [String: AnyCodableValue] = [
                "protocolVersion": .string(version),
                "capabilities": .dict([
                    "tools": .dict([:]),
                    "resources": .dict([:]),
                    "prompts": .dict([:]),
                ]),
                "serverInfo": .dict([
                    "name": .string(opts.serverName),
                    "version": .string(opts.serverVersion),
                ]),
            ]
            if let instructions = opts.instructions {
                result["instructions"] = .string(instructions)
            }
            return (.ok(id, .dict(result)), session)
        } catch {
            return (.error(id, code: MCPErrorCode.internalError.rawValue,
                           message: "Failed to create session: \(error.localizedDescription)"), nil)
        }
    }

    // MARK: - Tools

    private func handleToolsList(id: JSONRPCId, params: [String: AnyCodableValue]) -> JSONRPCResponse {
        var allTools = (catalog?.tools ?? []).map { $0.listEntry }
        if semanticDispatch != nil, catalog?.tool(named: MCPSemanticDispatchTool.name) == nil {
            allTools.append(MCPSemanticDispatchTool.listEntry)
        }

        let cursor: Int
        switch params["cursor"] {
        case nil, .null?:
            cursor = 0
        case .string(let c)?:
            guard let parsed = Int(c), parsed >= 0, parsed <= allTools.count else {
                return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Invalid cursor")
            }
            cursor = parsed
        default:
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Invalid cursor")
        }

        let pageSize = 100
        let page = Array(allTools.dropFirst(cursor).prefix(pageSize))
        var resultDict: [String: AnyCodableValue] = ["tools": .array(page.map { .dict($0) })]
        if cursor + pageSize < allTools.count {
            resultDict["nextCursor"] = .string(String(cursor + pageSize))
        }
        return .ok(id, .dict(resultDict))
    }

    private func handleToolsCall(id: JSONRPCId, params: [String: AnyCodableValue]) async -> JSONRPCResponse {
        guard case .string(let name) = params["name"], !name.isEmpty else {
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Missing tool name")
        }

        let arguments: [String: AnyCodableValue]
        switch params["arguments"] {
        case nil, .null?:
            arguments = [:]
        case .dict(let argsDict)?:
            arguments = argsDict
        default:
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "arguments must be an object")
        }

        // The explicit semantic meta-tool (a real tool of the same name wins).
        if name == MCPSemanticDispatchTool.name,
           let semanticDispatch,
           catalog?.tool(named: name) == nil {
            return .ok(id, await runSemanticDispatch(semanticDispatch, arguments: arguments))
        }

        // Exactly the named tool, or an error. Never a near match.
        guard let tool = catalog?.tool(named: name) else {
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Unknown tool: \(name)")
        }
        guard let toolExecutor else {
            return .error(id, code: MCPErrorCode.internalError.rawValue,
                          message: "Tool \(name) cannot run: no runtime is wired to this server")
        }

        let meta: [String: AnyCodableValue] = ["dev.smallchat/toolId": .string(tool.toolId)]
        do {
            let result = try await toolExecutor(tool, arguments)
            return .ok(id, mcpCallToolResult(result, meta: meta))
        } catch {
            // A failed tool is a tool result the model can see, not a protocol error.
            return .ok(id, mcpErrorResult("Tool \(name) failed: \(describeError(error))", meta: meta))
        }
    }

    private func runSemanticDispatch(
        _ handler: MCPSemanticDispatchHandler,
        arguments: [String: AnyCodableValue]
    ) async -> AnyCodableValue {
        guard case .string(let intent)? = arguments["intent"], !intent.isEmpty else {
            return mcpErrorResult("\(MCPSemanticDispatchTool.name) needs an \"intent\" string")
        }
        var toolArguments: [String: AnyCodableValue] = [:]
        if case .dict(let args)? = arguments["arguments"] { toolArguments = args }

        let outcome: TieredDispatchResult
        do {
            outcome = try await handler(intent, toolArguments)
        } catch {
            return mcpErrorResult("Semantic dispatch failed: \(describeError(error))")
        }

        switch outcome {
        case .dispatched(let result, let tier, let proof):
            return mcpCallToolResult(result, meta: [
                "dev.smallchat/resolution": .dict([
                    "status": .string("dispatched"),
                    "tier": .string(tier.rawValue),
                    "proof": encodeAsValue(proof),
                ]),
            ])

        case .decomposed(let subIntents, let proof):
            let text = "No tool was run. The intent decomposes into: " + subIntents.joined(separator: "; ")
            return .dict([
                "content": .array([.dict(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": .dict([
                    "status": .string("decomposed"),
                    "subIntents": .array(subIntents.map { .string($0) }),
                ]),
                "isError": .bool(false),
                "_meta": .dict(["dev.smallchat/resolution": .dict(["status": .string("decomposed"), "proof": encodeAsValue(proof)])]),
            ])

        case .refinement(let refinement):
            var text = "No tool was run: \(refinement.reason)"
            if !refinement.clarifyingQuestions.isEmpty {
                text += "\n" + refinement.clarifyingQuestions.map { "- \($0)" }.joined(separator: "\n")
            }
            return .dict([
                "content": .array([.dict(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": encodeAsValue(refinement),
                "isError": .bool(false),
                "_meta": .dict(["dev.smallchat/resolution": .dict(["status": .string(ToolRefinement.mcpResultType)])]),
            ])

        case .strictAmbiguityError(let reason, let proof):
            return mcpErrorResult("No tool was run: \(reason)", meta: [
                "dev.smallchat/resolution": .dict(["status": .string("ambiguous"), "proof": encodeAsValue(proof)]),
            ])
        }
    }

    // MARK: - Resources

    private func handleResourcesList(
        id: JSONRPCId,
        params: [String: AnyCodableValue],
        sessionId: String?
    ) async -> JSONRPCResponse {
        let cursor: String?
        if case .string(let c) = params["cursor"] {
            cursor = c
        } else {
            cursor = nil
        }

        let result = await resourceRegistry.list(cursor: cursor)
        let resourceValues: [AnyCodableValue] = result.resources.map { resource in
            var dict: [String: AnyCodableValue] = [
                "uri": .string(resource.uri),
                "name": .string(resource.name),
                "providerId": .string(resource.providerId),
            ]
            if let desc = resource.description { dict["description"] = .string(desc) }
            if let mime = resource.mimeType { dict["mimeType"] = .string(mime) }
            return .dict(dict)
        }

        var resultDict: [String: AnyCodableValue] = ["resources": .array(resourceValues)]
        if let nc = result.nextCursor {
            resultDict["nextCursor"] = .string(nc)
        }

        return .ok(id, .dict(resultDict))
    }

    private func handleResourcesRead(
        id: JSONRPCId,
        params: [String: AnyCodableValue],
        sessionId: String?
    ) async -> JSONRPCResponse {
        guard case .string(let uri) = params["uri"] else {
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Missing resource URI")
        }

        do {
            let content = try await resourceRegistry.read(uri: uri)
            var contentDict: [String: AnyCodableValue] = [
                "uri": .string(content.uri),
                "mimeType": .string(content.mimeType),
            ]
            if let text = content.text { contentDict["text"] = .string(text) }
            if let blob = content.blob { contentDict["blob"] = .string(blob) }

            return .ok(id, .dict(["contents": .array([.dict(contentDict)])]))
        } catch is ResourceNotFoundError {
            return .error(id, code: MCPErrorCode.resourceNotFound.rawValue,
                          message: "Resource not found: \(uri)")
        } catch {
            return .error(id, code: MCPErrorCode.internalError.rawValue,
                          message: error.localizedDescription)
        }
    }

    private func handleResourcesTemplatesList(
        id: JSONRPCId,
        sessionId: String?
    ) async -> JSONRPCResponse {
        let templates = await resourceRegistry.listTemplates()
        let templateValues: [AnyCodableValue] = templates.map { template in
            var dict: [String: AnyCodableValue] = [
                "uriTemplate": .string(template.uriTemplate),
                "name": .string(template.name),
            ]
            if let desc = template.description { dict["description"] = .string(desc) }
            if let mime = template.mimeType { dict["mimeType"] = .string(mime) }
            return .dict(dict)
        }

        return .ok(id, .dict(["resourceTemplates": .array(templateValues)]))
    }

    // MARK: - Prompts

    private func handlePromptsList(
        id: JSONRPCId,
        params: [String: AnyCodableValue],
        sessionId: String?
    ) async -> JSONRPCResponse {
        let result = await promptRegistry.list()
        let promptValues: [AnyCodableValue] = result.prompts.map { prompt in
            var dict: [String: AnyCodableValue] = [
                "name": .string(prompt.name),
            ]
            if let desc = prompt.description { dict["description"] = .string(desc) }
            if let args = prompt.arguments {
                dict["arguments"] = .array(args.map { arg in
                    var argDict: [String: AnyCodableValue] = ["name": .string(arg.name)]
                    if let desc = arg.description { argDict["description"] = .string(desc) }
                    if let req = arg.required { argDict["required"] = .bool(req) }
                    return .dict(argDict)
                })
            }
            return .dict(dict)
        }

        return .ok(id, .dict(["prompts": .array(promptValues)]))
    }

    private func handlePromptsGet(
        id: JSONRPCId,
        params: [String: AnyCodableValue],
        sessionId: String?
    ) async -> JSONRPCResponse {
        guard case .string(let name) = params["name"] else {
            return .error(id, code: MCPErrorCode.invalidParams.rawValue, message: "Missing prompt name")
        }

        // Extract string arguments
        var args: [String: String]?
        if case .dict(let argsDict) = params["arguments"] {
            args = [:]
            for (k, v) in argsDict {
                if case .string(let s) = v {
                    args?[k] = s
                }
            }
        }

        do {
            let result = try await promptRegistry.get(name: name, args: args)
            var resultDict: [String: AnyCodableValue] = [:]
            if let desc = result.description {
                resultDict["description"] = .string(desc)
            }

            let messageValues: [AnyCodableValue] = result.messages.map { msg in
                var msgDict: [String: AnyCodableValue] = [
                    "role": .string(msg.role.rawValue),
                ]
                switch msg.content {
                case .text(let text):
                    msgDict["content"] = .dict(["type": .string("text"), "text": .string(text)])
                case .image(let data, let mimeType):
                    msgDict["content"] = .dict(["type": .string("image"), "data": .string(data), "mimeType": .string(mimeType)])
                case .resource(let uri, let text, let mimeType):
                    var resDict: [String: AnyCodableValue] = ["uri": .string(uri)]
                    if let t = text { resDict["text"] = .string(t) }
                    if let m = mimeType { resDict["mimeType"] = .string(m) }
                    msgDict["content"] = .dict(["type": .string("resource"), "resource": .dict(resDict)])
                }
                return .dict(msgDict)
            }
            resultDict["messages"] = .array(messageValues)

            return .ok(id, .dict(resultDict))
        } catch is PromptNotFoundError {
            return .error(id, code: MCPErrorCode.promptNotFound.rawValue,
                          message: "Prompt not found: \(name)")
        } catch {
            return .error(id, code: MCPErrorCode.internalError.rawValue,
                          message: error.localizedDescription)
        }
    }
}
