import Testing
import Foundation
@testable import SmallChatMCP
import SmallChatCore
import SmallChatRuntime

// MARK: - Helpers

/// demo/echo, demo/fail and other/echo.
func makeTestArtifact(endpoint: String? = nil, transportType: String = "mcp") -> SerializedArtifact {
    func entry(_ provider: String, _ tool: String) -> DispatchEntry {
        DispatchEntry(
            providerId: provider,
            toolName: tool,
            transportType: transportType,
            inputSchema: ["type": .string("object")],
            description: "\(tool) from \(provider)",
            endpoint: endpoint
        )
    }
    return SerializedArtifact(
        stats: ArtifactStats(toolCount: 3, uniqueSelectorCount: 3, providerCount: 2, collisionCount: 0),
        selectors: [:],
        dispatchTables: [
            "demo": ["demo.echo": entry("demo", "echo"), "demo.fail": entry("demo", "fail")],
            "other": ["other.echo": entry("other", "echo")],
        ]
    )
}

private func makeRouter(naming: MCPToolNaming = .aggregate) async throws -> MCPRouter {
    let router = MCPRouter(
        sessionStore: try SessionStore(dbPath: ":memory:"),
        resourceRegistry: ResourceRegistry(),
        promptRegistry: PromptRegistry(),
        options: RouterOptions(toolNaming: naming)
    )
    await router.setArtifact(makeTestArtifact())
    return router
}

private func toolsCallRequest(name: String, arguments: [String: AnyCodableValue] = [:]) -> JSONRPCRequest {
    JSONRPCRequest(
        id: .string("req-1"),
        method: MCPMethod.toolsCall.rawValue,
        params: [
            "name": .string(name),
            "arguments": .dict(arguments),
        ]
    )
}

private func emptyProof(tier: DispatchTier = .high) -> ResolutionProof {
    var p = ResolutionProof()
    p.finalTier = tier
    return p
}

/// Records which tools the executor was asked to run.
final class CallRecorder: Sendable {
    private let calls = PlatformLock<[String]>(initialState: [])
    func record(_ toolId: String) { calls.withLock { $0.append(toolId) } }
    var all: [String] { calls.withLock { $0 } }
}

private func body(_ response: JSONRPCResponse?) throws -> [String: AnyCodableValue] {
    let response = try #require(response)
    guard case .dict(let body) = response.result else {
        Issue.record("expected a result object, got \(String(describing: response.error))")
        return [:]
    }
    return body
}

// MARK: - Suite

@Suite("tools/call router wiring")
struct ToolsCallRouterTests {

    @Test("without a runtime, tools/call is an error, never a fake success")
    func noRuntimeIsAnError() async throws {
        let router = try await makeRouter()
        let resp = await router.handle(request: toolsCallRequest(name: "demo__echo"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error != nil)
        #expect(result.result == nil)
    }

    @Test("an exact name runs exactly that tool")
    func exactNameRunsThatTool() async throws {
        let router = try await makeRouter()
        let recorder = CallRecorder()
        await router.setToolExecutor { tool, args in
            recorder.record(tool.toolId)
            return ToolResult(codableContent: .dict(args))
        }

        let result = try body(await router.handle(
            request: toolsCallRequest(name: "other__echo", arguments: ["x": .int(1)]),
            sessionId: nil
        ))
        #expect(recorder.all == ["other/echo"])
        #expect(result["isError"] == .bool(false))
        #expect(result["structuredContent"] == .dict(["x": .int(1)]))
        #expect(result["content"] == .array([.dict(["type": .string("text"), "text": .string(#"{"x":1}"#)])]))
        guard case .dict(let meta)? = result["_meta"] else { Issue.record("missing _meta"); return }
        #expect(meta["dev.smallchat/toolId"] == .string("other/echo"))
    }

    @Test("a name that is not listed is an error and runs nothing")
    func unknownNameIsAnError() async throws {
        let router = try await makeRouter()
        let recorder = CallRecorder()
        await router.setToolExecutor { tool, _ in
            recorder.record(tool.toolId)
            return ToolResult(content: "ran")
        }
        await router.setSemanticDispatchHandler { _, _ in
            recorder.record("semantic")
            return .dispatched(result: ToolResult(content: "fuzzy"), tier: .high, proof: emptyProof())
        }

        // The upstream name alone, a near miss, and the canonical id are not listed names.
        for name in ["echo", "demo__ech0", "demo/echo"] {
            let response = try #require(await router.handle(request: toolsCallRequest(name: name), sessionId: nil))
            #expect(response.error?.code == MCPErrorCode.invalidParams.rawValue)
        }
        #expect(recorder.all.isEmpty)
    }

    @Test("a tool that fails is an isError result carrying the reason")
    func failingToolIsErrorResult() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "upstream exploded" } }
        let router = try await makeRouter()
        await router.setToolExecutor { _, _ in throw Boom() }

        let result = try body(await router.handle(request: toolsCallRequest(name: "demo__fail"), sessionId: nil))
        #expect(result["isError"] == .bool(true))
        guard case .array(let content)? = result["content"], case .dict(let first)? = content.first,
              case .string(let text)? = first["text"] else {
            Issue.record("missing text content"); return
        }
        #expect(text.contains("upstream exploded"))
    }

    @Test("isError from the tool propagates")
    func toolIsErrorPropagates() async throws {
        let router = try await makeRouter()
        await router.setToolExecutor { _, _ in ToolResult(content: "boom", isError: true) }
        let result = try body(await router.handle(request: toolsCallRequest(name: "demo__fail"), sessionId: nil))
        #expect(result["isError"] == .bool(true))
    }

    @Test("an upstream CallToolResult is passed through")
    func upstreamResultPassedThrough() async throws {
        let router = try await makeRouter()
        let upstream: AnyCodableValue = .dict([
            "content": .array([.dict(["type": .string("text"), "text": .string("hi")])]),
            "structuredContent": .dict(["n": .int(2)]),
            "isError": .bool(false),
        ])
        await router.setToolExecutor { _, _ in
            ToolResult(content: upstream, isError: false, metadata: [mcpCallToolResultMetadataKey: true])
        }
        var result = try body(await router.handle(request: toolsCallRequest(name: "demo__echo"), sessionId: nil))
        result["_meta"] = nil
        #expect(AnyCodableValue.dict(result) == upstream)
    }

    @Test("arguments that are not an object are invalid params")
    func nonObjectArguments() async throws {
        let router = try await makeRouter()
        await router.setToolExecutor { _, _ in ToolResult(content: "ran") }
        let request = JSONRPCRequest(id: .int(1), method: "tools/call", params: [
            "name": .string("demo__echo"), "arguments": .array([]),
        ])
        let response = try #require(await router.handle(request: request, sessionId: nil))
        #expect(response.error?.code == MCPErrorCode.invalidParams.rawValue)
    }

    @Test("missing tool name returns invalidParams error")
    func missingToolName() async throws {
        let router = try await makeRouter()
        let req = JSONRPCRequest(
            id: .string("req-x"),
            method: MCPMethod.toolsCall.rawValue,
            params: [:]
        )
        let resp = await router.handle(request: req, sessionId: nil)
        let result = try #require(resp)
        #expect(result.error != nil)
        #expect(result.error?.code == MCPErrorCode.invalidParams.rawValue)
    }

    @Test("tools/list lists <provider>__<tool> names in a stable order")
    func toolsListNames() async throws {
        let router = try await makeRouter()
        let result = try body(await router.handle(
            request: JSONRPCRequest(id: .int(1), method: "tools/list"), sessionId: nil
        ))
        guard case .array(let tools)? = result["tools"] else { Issue.record("missing tools"); return }
        let names = tools.compactMap { tool -> String? in
            guard case .dict(let d) = tool, case .string(let name)? = d["name"] else { return nil }
            return name
        }
        #expect(names == ["demo__echo", "demo__fail", "other__echo"])
    }

    @Test("provider naming lists one provider under upstream names")
    func providerNaming() async throws {
        let router = try await makeRouter(naming: .provider("demo"))
        let recorder = CallRecorder()
        await router.setToolExecutor { tool, _ in
            recorder.record(tool.toolId)
            return ToolResult(content: "ok")
        }
        let catalog = try #require(await router.toolCatalog)
        #expect(catalog.tools.map(\.name) == ["echo", "fail"])
        _ = await router.handle(request: toolsCallRequest(name: "echo"), sessionId: nil)
        #expect(recorder.all == ["demo/echo"])
    }
}

// MARK: - Semantic meta-tool

@Suite("smallchat_dispatch meta-tool")
struct SemanticDispatchToolTests {

    private func dispatch(_ intent: String) -> JSONRPCRequest {
        toolsCallRequest(name: MCPSemanticDispatchTool.name, arguments: ["intent": .string(intent)])
    }

    @Test("is listed and callable only when semantic dispatch is wired")
    func listedOnlyWhenWired() async throws {
        let router = try await makeRouter()
        await router.setToolExecutor { _, _ in ToolResult(content: "ran") }
        let unwired = try #require(await router.handle(request: dispatch("echo something"), sessionId: nil))
        #expect(unwired.error?.code == MCPErrorCode.invalidParams.rawValue)

        await router.setSemanticDispatchHandler { _, _ in
            .dispatched(result: ToolResult(content: "hello"), tier: .high, proof: emptyProof())
        }
        let list = try body(await router.handle(request: JSONRPCRequest(id: .int(1), method: "tools/list"), sessionId: nil))
        guard case .array(let tools)? = list["tools"] else { Issue.record("missing tools"); return }
        #expect(tools.contains { tool in
            if case .dict(let d) = tool, d["name"] == .string(MCPSemanticDispatchTool.name) { return true }
            return false
        })
    }

    @Test("dispatched result returns the tool's content with the tier")
    func dispatchedResult() async throws {
        let router = try await makeRouter()
        await router.setSemanticDispatchHandler { intent, _ in
            #expect(intent == "greet")
            return .dispatched(result: ToolResult(codableContent: .string("hello")), tier: .high, proof: emptyProof(tier: .high))
        }
        let result = try body(await router.handle(request: dispatch("greet"), sessionId: nil))
        #expect(result["isError"] == .bool(false))
        #expect(result["content"] == .array([.dict(["type": .string("text"), "text": .string("hello")])]))
        guard case .dict(let meta)? = result["_meta"],
              case .dict(let resolution)? = meta["dev.smallchat/resolution"] else {
            Issue.record("missing resolution meta"); return
        }
        #expect(resolution["tier"] == .string("high"))
    }

    @Test("refinement runs nothing and says so")
    func refinementResult() async throws {
        let router = try await makeRouter()
        await router.setSemanticDispatchHandler { intent, _ in
            .refinement(ToolRefinement(originalIntent: intent, reason: "no confident match", proof: emptyProof(tier: .none)))
        }
        let result = try body(await router.handle(request: dispatch("fuzzy"), sessionId: nil))
        #expect(result["isError"] == .bool(false))
        guard case .dict(let structured)? = result["structuredContent"] else { Issue.record("missing structuredContent"); return }
        #expect(structured["originalIntent"] == .string("fuzzy"))
    }

    @Test("decomposed result lists sub-intents")
    func decomposedResult() async throws {
        let router = try await makeRouter()
        await router.setSemanticDispatchHandler { _, _ in
            .decomposed(subIntents: ["step one", "step two"], proof: emptyProof(tier: .low))
        }
        let result = try body(await router.handle(request: dispatch("compound"), sessionId: nil))
        guard case .dict(let structured)? = result["structuredContent"] else { Issue.record("missing structuredContent"); return }
        #expect(structured["subIntents"] == .array([.string("step one"), .string("step two")]))
    }

    @Test("strict ambiguity is isError")
    func strictAmbiguityResult() async throws {
        let router = try await makeRouter()
        await router.setSemanticDispatchHandler { _, _ in
            .strictAmbiguityError(reason: "ambiguous under strict mode", proof: emptyProof(tier: .medium))
        }
        let result = try body(await router.handle(request: dispatch("ambiguous"), sessionId: nil))
        #expect(result["isError"] == .bool(true))
    }

    @Test("a handler that throws is an isError result")
    func handlerThrows() async throws {
        struct DispatchFailure: Error {}
        let router = try await makeRouter()
        await router.setSemanticDispatchHandler { _, _ in throw DispatchFailure() }
        let result = try body(await router.handle(request: dispatch("boom"), sessionId: nil))
        #expect(result["isError"] == .bool(true))
    }
}

// MARK: - Catalog

@Suite("MCP tool catalog")
struct MCPToolCatalogTests {

    @Test("names that are not valid MCP names are reported, not renamed")
    func invalidNamesSkipped() {
        let artifact = SerializedArtifact(
            stats: ArtifactStats(toolCount: 2, uniqueSelectorCount: 2, providerCount: 1, collisionCount: 0),
            selectors: [:],
            dispatchTables: ["p": [
                "a": DispatchEntry(providerId: "p", toolName: "good_tool", transportType: "mcp"),
                "b": DispatchEntry(providerId: "p", toolName: "bad tool!", transportType: "mcp"),
            ]]
        )
        let catalog = MCPToolCatalog(artifact: artifact)
        #expect(catalog.tools.map(\.name) == ["p__good_tool"])
        #expect(catalog.skipped.map(\.toolId) == ["p/bad tool!"])
    }

    @Test("colliding names are all left out")
    func collisionsSkipped() {
        let artifact = SerializedArtifact(
            stats: ArtifactStats(toolCount: 2, uniqueSelectorCount: 2, providerCount: 2, collisionCount: 0),
            selectors: [:],
            dispatchTables: [
                "a__b": ["x": DispatchEntry(providerId: "a__b", toolName: "c", transportType: "mcp")],
                "a": ["y": DispatchEntry(providerId: "a", toolName: "b__c", transportType: "mcp")],
            ]
        )
        let catalog = MCPToolCatalog(artifact: artifact)
        #expect(catalog.tools.isEmpty)
        #expect(Set(catalog.skipped.map(\.toolId)) == ["a__b/c", "a/b__c"])
    }
}

// MARK: - ToolProxy

@Suite("ToolProxy execution")
struct ToolProxyExecutionTests {

    @Test("a proxy without an executor refuses to run instead of faking success")
    func proxyWithoutExecutorThrows() async {
        let proxy = ToolProxy(providerId: "p", toolName: "t", transportType: .mcp) {
            ToolSchema(name: "t", description: "", inputSchema: JSONSchemaType(type: "object"))
        }
        await #expect(throws: ToolNotExecutableError.self) {
            _ = try await proxy.execute(args: [:])
        }
    }

    @Test("a proxy with an executor runs it")
    func proxyWithExecutorRuns() async throws {
        let proxy = ToolProxy(providerId: "p", toolName: "t", transportType: .mcp, schemaLoader: {
            ToolSchema(name: "t", description: "", inputSchema: JSONSchemaType(type: "object"))
        }, executor: { _ in ToolResult(content: "ran") })
        let result = try await proxy.execute(args: [:])
        #expect(result.content as? String == "ran")
    }
}
