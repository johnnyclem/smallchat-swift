import Testing
import Foundation
@testable import SmallChatMCP
import SmallChatCore
import SmallChatRuntime

// MARK: - Helpers

private func makeRouter() throws -> MCPRouter {
    MCPRouter(
        sessionStore: try SessionStore(dbPath: ":memory:"),
        resourceRegistry: ResourceRegistry(),
        promptRegistry: PromptRegistry(),
        sseBroker: SSEBroker()
    )
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

// MARK: - Suite

@Suite("tools/call router wiring")
struct ToolsCallRouterTests {

    @Test("no bridge wired returns placeholder ok")
    func noBridgePlaceholder() async throws {
        let router = try makeRouter()
        let req = toolsCallRequest(name: "some_tool")
        let resp = await router.handle(request: req, sessionId: nil)
        let result = try #require(resp)
        #expect(result.error == nil)
        guard case .dict(let body) = result.result,
              case .string(let status) = body["status"] else {
            Issue.record("unexpected response shape")
            return
        }
        #expect(status == "ok")
        guard case .dict(let inner) = body["result"],
              case .string(let note) = inner["note"] else {
            Issue.record("expected note in result")
            return
        }
        #expect(note.contains("runtime dispatch pending"))
    }

    @Test("dispatched result returns ok with content and meta")
    func dispatchedResult() async throws {
        let router = try makeRouter()
        await router.setRefinementHandler { _, _ in
            .dispatched(
                result: ToolResult(codableContent: .string("hello"), isError: false),
                tier: .high,
                proof: emptyProof(tier: .high)
            )
        }
        let resp = await router.handle(request: toolsCallRequest(name: "greet"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error == nil)
        guard case .dict(let body) = result.result else {
            Issue.record("unexpected response shape"); return
        }
        guard case .string(let status) = body["status"] else {
            Issue.record("missing status"); return
        }
        #expect(status == "ok")
        guard case .bool(let isError) = body["isError"] else {
            Issue.record("missing isError"); return
        }
        #expect(isError == false)
        guard case .array(let content) = body["content"],
              !content.isEmpty else {
            Issue.record("missing content array"); return
        }
        guard case .dict(let meta) = body["meta"],
              case .string(let tier) = meta["tier"] else {
            Issue.record("missing meta.tier"); return
        }
        #expect(tier == "high")
    }

    @Test("dispatched isError=true propagates")
    func dispatchedIsError() async throws {
        let router = try makeRouter()
        await router.setRefinementHandler { _, _ in
            .dispatched(
                result: ToolResult(codableContent: .string("boom"), isError: true),
                tier: .medium,
                proof: emptyProof(tier: .medium)
            )
        }
        let resp = await router.handle(request: toolsCallRequest(name: "bad_tool"), sessionId: nil)
        let result = try #require(resp)
        guard case .dict(let body) = result.result,
              case .bool(let isError) = body["isError"] else {
            Issue.record("missing isError"); return
        }
        #expect(isError == true)
    }

    @Test("refinement result returns tool_refinement_needed")
    func refinementResult() async throws {
        let router = try makeRouter()
        await router.setRefinementHandler { intent, _ in
            .refinement(ToolRefinement(
                originalIntent: intent,
                reason: "no confident match",
                proof: emptyProof(tier: .none)
            ))
        }
        let resp = await router.handle(request: toolsCallRequest(name: "fuzzy_tool"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error == nil)
        guard case .dict(let body) = result.result,
              case .string(let status) = body["status"] else {
            Issue.record("missing status"); return
        }
        #expect(status == ToolRefinement.mcpResultType)
        guard case .dict(let inner) = body["result"],
              case .string(let intent) = inner["originalIntent"] else {
            Issue.record("missing originalIntent in refinement payload"); return
        }
        #expect(intent == "fuzzy_tool")
    }

    @Test("decomposed result returns decomposed status with subIntents")
    func decomposedResult() async throws {
        let router = try makeRouter()
        await router.setRefinementHandler { _, _ in
            .decomposed(subIntents: ["step one", "step two"], proof: emptyProof(tier: .low))
        }
        let resp = await router.handle(request: toolsCallRequest(name: "compound_action"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error == nil)
        guard case .dict(let body) = result.result,
              case .string(let status) = body["status"] else {
            Issue.record("missing status"); return
        }
        #expect(status == "decomposed")
        guard case .array(let subs) = body["subIntents"] else {
            Issue.record("missing subIntents"); return
        }
        #expect(subs.count == 2)
    }

    @Test("strictAmbiguityError returns error status with isError true")
    func strictAmbiguityResult() async throws {
        let router = try makeRouter()
        await router.setRefinementHandler { _, _ in
            .strictAmbiguityError(reason: "ambiguous under strict mode", proof: emptyProof(tier: .medium))
        }
        let resp = await router.handle(request: toolsCallRequest(name: "ambiguous_tool"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error == nil)
        guard case .dict(let body) = result.result,
              case .string(let status) = body["status"],
              case .bool(let isError) = body["isError"] else {
            Issue.record("missing status or isError"); return
        }
        #expect(status == "error")
        #expect(isError == true)
    }

    @Test("bridge that throws returns JSON-RPC error")
    func bridgeThrows() async throws {
        struct DispatchFailure: Error {}
        let router = try makeRouter()
        await router.setRefinementHandler { _, _ in
            throw DispatchFailure()
        }
        let resp = await router.handle(request: toolsCallRequest(name: "boom"), sessionId: nil)
        let result = try #require(resp)
        #expect(result.error != nil)
    }

    @Test("missing tool name returns invalidParams error")
    func missingToolName() async throws {
        let router = try makeRouter()
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
}
