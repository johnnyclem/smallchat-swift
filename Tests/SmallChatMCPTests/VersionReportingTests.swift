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
            promptRegistry: PromptRegistry(),
            sseBroker: SSEBroker()
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
}
