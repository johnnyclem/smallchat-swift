import Testing
import Foundation
@testable import SmallChatMCP
import SmallChatCore
import SmallChatRuntime
import SmallChatEmbedding
import SmallChatCompiler

// MARK: - Helpers

/// A compiled artifact (format 1.0, hash embedder at 16 dimensions) of
/// `tools`; by default demo/echo, demo/fail and other/echo.
func makeTestArtifact(
    endpoints: [String: String] = [:],
    tools: [(provider: String, name: String)] = [("demo", "echo"), ("demo", "fail"), ("other", "echo")]
) async throws -> ArtifactV1 {
    var order: [String] = []
    var names: [String: [String]] = [:]
    for tool in tools {
        if names[tool.provider] == nil { order.append(tool.provider) }
        names[tool.provider, default: []].append(tool.name)
    }
    let manifests = order.sorted().map { provider in
        ProviderManifest(
            id: provider,
            name: provider,
            tools: names[provider]!.map { name in
                ToolDefinition(
                    name: name,
                    description: "\(name) from \(provider)",
                    inputSchema: JSONSchemaType(type: "object"),
                    providerId: provider,
                    transportType: .mcp
                )
            },
            transportType: .mcp,
            endpoint: endpoints[provider]
        )
    }
    let embedder = LocalEmbedder(dimensions: 16)
    let compiler = ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex(), options: CompilerOptions(allowDuplicates: true))
    let result = try await compiler.compile(manifests)
    return try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
}

private func makeRouter(naming: MCPToolNaming = .aggregate) async throws -> MCPRouter {
    let router = MCPRouter(
        sessionStore: try SessionStore(dbPath: ":memory:"),
        resourceRegistry: ResourceRegistry(),
        promptRegistry: PromptRegistry(),
        options: RouterOptions(toolNaming: naming)
    )
    await router.setArtifact(try await makeTestArtifact())
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

/// Embeds `intent` as e0 and anything else as the last axis.
private struct AxisEmbedder: Embedder {
    let intent: String
    let dimensions = 3
    func embed(_ text: String) async throws -> [Float] {
        text == intent ? [1, 0, 0] : [0, 0, 1]
    }
}

/// A runtime holding demo/echo, whose cosine similarity to `intent` is `score`.
private func resolvingRuntime(intent: String, score: Float, recorder: CallRecorder) async throws -> ToolRuntime {
    let runtime = ToolRuntime(vectorIndex: MemoryVectorIndex(), embedder: AxisEmbedder(intent: intent))
    let selector = try await runtime.selectorTable.register(
        embedding: [score, (1 - score * score).squareRoot(), 0],
        canonical: "demo.echo"
    )
    let proxy = ToolProxy(
        providerId: "demo",
        toolName: "echo",
        transportType: .local,
        schemaLoader: { ToolSchema(name: "echo", description: intent, inputSchema: JSONSchemaType(type: "object")) },
        executor: { _ in recorder.record("demo/echo"); return ToolResult(content: "ran") }
    )
    let cls = ToolClass(name: "demo")
    cls.addMethod(selector, imp: proxy)
    try await runtime.registerClass(cls)
    return runtime
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
        struct NotCalled: Error {}
        await router.setResolveHandler { _, _ in
            recorder.record("resolve")
            throw NotCalled()
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

// MARK: - Resolve meta-tool

@Suite("smallchat_resolve meta-tool")
struct ResolveToolTests {

    private func resolve(_ intent: String) -> JSONRPCRequest {
        toolsCallRequest(name: MCPResolveTool.name, arguments: ["intent": .string(intent)])
    }

    @Test("is listed and callable only when resolution is wired, and never runs a tool")
    func listedOnlyWhenWired() async throws {
        let router = try await makeRouter()
        let recorder = CallRecorder()
        await router.setToolExecutor { tool, _ in recorder.record(tool.toolId); return ToolResult(content: "ran") }
        let unwired = try #require(await router.handle(request: resolve("echo something"), sessionId: nil))
        #expect(unwired.error?.code == MCPErrorCode.invalidParams.rawValue)

        let runtime = try await resolvingRuntime(intent: "echo something", score: 0.97, recorder: recorder)
        await router.setResolveHandler { intent, _ in try await runtime.resolve(intent) }
        let list = try body(await router.handle(request: JSONRPCRequest(id: .int(1), method: "tools/list"), sessionId: nil))
        guard case .array(let tools)? = list["tools"] else { Issue.record("missing tools"); return }
        #expect(tools.contains { tool in
            if case .dict(let d) = tool, d["name"] == .string(MCPResolveTool.name) { return true }
            return false
        })

        let result = try body(await router.handle(request: resolve("echo something"), sessionId: nil))
        #expect(result["isError"] == .bool(false))
        guard case .dict(let proposal)? = result["structuredContent"] else { Issue.record("missing structuredContent"); return }
        #expect(proposal["outcome"] == .string("resolved"))
        #expect(proposal["toolId"] == .string("demo/echo"))
        #expect(proposal["name"] == .string("demo__echo"))
        #expect(proposal["tier"] == .string("exact"))
        guard case .dict(let meta)? = result["_meta"], case .dict(let resolution)? = meta["dev.smallchat/resolution"] else {
            Issue.record("missing resolution meta"); return
        }
        #expect(resolution["ran"] == .null)
        #expect(recorder.all.isEmpty)
    }

    @Test("an intent below HIGH proposes nothing and runs nothing")
    func subHighProposesNothing() async throws {
        let router = try await makeRouter()
        let recorder = CallRecorder()
        await router.setToolExecutor { tool, _ in recorder.record(tool.toolId); return ToolResult(content: "ran") }
        let runtime = try await resolvingRuntime(intent: "echo maybe", score: 0.8, recorder: recorder)
        await router.setResolveHandler { intent, _ in try await runtime.resolve(intent) }
        let result = try body(await router.handle(request: resolve("echo maybe"), sessionId: nil))
        #expect(result["isError"] == .bool(false))
        guard case .dict(let proposal)? = result["structuredContent"] else { Issue.record("missing structuredContent"); return }
        #expect(proposal["outcome"] == .string("needs-disambiguation"))
        #expect(proposal["name"] == .null)
        #expect(recorder.all.isEmpty)
    }

    @Test("a missing intent, or args that are not an object, is isError")
    func badArguments() async throws {
        let router = try await makeRouter()
        await router.setResolveHandler { _, _ in Issue.record("must not be called"); throw CancellationError() }
        let missing = try body(await router.handle(request: toolsCallRequest(name: MCPResolveTool.name), sessionId: nil))
        #expect(missing["isError"] == .bool(true))
        let badArgs = try body(await router.handle(
            request: toolsCallRequest(name: MCPResolveTool.name, arguments: ["intent": .string("x"), "args": .int(1)]),
            sessionId: nil
        ))
        #expect(badArgs["isError"] == .bool(true))
    }

    @Test("a handler that throws is an isError result")
    func handlerThrows() async throws {
        struct ResolveFailure: Error {}
        let router = try await makeRouter()
        await router.setResolveHandler { _, _ in throw ResolveFailure() }
        let result = try body(await router.handle(request: resolve("boom"), sessionId: nil))
        #expect(result["isError"] == .bool(true))
    }
}

// MARK: - Catalog

@Suite("MCP tool catalog")
struct MCPToolCatalogTests {

    @Test("names that are not valid MCP names are reported, not renamed")
    func invalidNamesSkipped() async throws {
        let artifact = try await makeTestArtifact(tools: [("p", "good_tool"), ("p", "bad tool!")])
        let catalog = MCPToolCatalog(artifact: artifact)
        #expect(catalog.tools.map(\.name) == ["p__good_tool"])
        #expect(catalog.skipped.map(\.toolId) == ["p/bad tool!"])
    }

    @Test("names cannot collide: a provider id with \"__\" is served only with --provider")
    func collisionsImpossible() async throws {
        let artifact = try await makeTestArtifact(tools: [("a__b", "c"), ("a", "b__c")])
        let catalog = MCPToolCatalog(artifact: artifact)
        // 0.6 listed neither (both wanted "a__b__c"). The suite rule
        // (spec/tool-id) makes the first "__" always end the provider id.
        #expect(catalog.tools.map(\.toolId) == ["a/b__c"])
        #expect(catalog.tools.map(\.name) == ["a__b__c"])
        #expect(catalog.skipped.map(\.toolId) == ["a__b/c"])
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
