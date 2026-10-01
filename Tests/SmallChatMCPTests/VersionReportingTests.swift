import Testing
import Foundation
@testable import SmallChatMCP
import SmallChatCore

/// The MCP server, router and client must all report the one package version
/// (before 1.0 they reported "0.6.0" and "0.1.0" from separate literals).
@Suite("MCP version reporting")
struct MCPVersionReportingTests {

    @Test("server constants and router defaults use SmallChatVersion.current")
    func constantsUsePackageVersion() {
        #expect(mcpServerVersion == SmallChatVersion.current)
        #expect(RouterOptions().serverVersion == SmallChatVersion.current)
    }

    @Test("initialize reports SmallChatVersion.current as serverInfo.version")
    func initializeReportsPackageVersion() async throws {
        let router = MCPRouter(
            sessionStore: try SessionStore(dbPath: ":memory:"),
            resourceRegistry: ResourceRegistry(),
            promptRegistry: PromptRegistry()
        )
        let request = JSONRPCRequest(
            id: .string("init-1"),
            method: MCPMethod.initialize.rawValue,
            params: [
                "protocolVersion": .string(mcpProtocolVersion),
                "clientInfo": .dict(["name": .string("test"), "version": .string("0")]),
            ]
        )
        let response = try #require(await router.handle(request: request, sessionId: nil))
        guard case .dict(let result) = response.result,
              case .dict(let serverInfo) = result["serverInfo"],
              case .string(let version) = serverInfo["version"] else {
            Issue.record("unexpected initialize response shape")
            return
        }
        #expect(version == SmallChatVersion.current)
    }

    @Test("initialize echoes a supported protocol version and offers the newest otherwise")
    func protocolNegotiation() async throws {
        let router = MCPRouter(
            sessionStore: try SessionStore(dbPath: ":memory:"),
            resourceRegistry: ResourceRegistry(),
            promptRegistry: PromptRegistry()
        )
        func negotiated(_ requested: String?) async -> String? {
            var params: [String: AnyCodableValue] = ["clientInfo": .dict(["name": .string("t"), "version": .string("0")])]
            if let requested { params["protocolVersion"] = .string(requested) }
            let (response, _) = await router.initialize(request: JSONRPCRequest(id: .int(1), method: "initialize", params: params))
            guard case .dict(let result) = response.result, case .string(let v) = result["protocolVersion"] else { return nil }
            return v
        }
        #expect(await negotiated("2025-06-18") == "2025-06-18")
        #expect(await negotiated("2025-11-25") == "2025-11-25")
        // Not implemented: 2024-11-05's HTTP+SSE transport, 2025-03-26's batches.
        #expect(await negotiated("2024-11-05") == "2025-11-25")
        #expect(await negotiated("2025-03-26") == "2025-11-25")
        #expect(await negotiated(nil) == "2025-11-25")
    }
}
