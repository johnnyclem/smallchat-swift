import Testing
import Foundation
@testable import SmallChatMCP
import SmallChatCore

@Suite("AppResourceHandler")
struct AppResourceHandlerTests {

    // MARK: - AppResourceHandler direct

    @Test("read returns text/html;profile=mcp-app for registered URI")
    func readReturnsCorrectMIME() async throws {
        let handler = AppResourceHandler(
            providerId: "ui-app-test",
            embeddedHTML: ["ui://test/index.html": "<html><body>Hello</body></html>"]
        )
        let content = try await handler.read(uri: "ui://test/index.html")
        #expect(content.mimeType == appResourceMIMEType)
        #expect(content.text == "<html><body>Hello</body></html>")
        #expect(content.uri == "ui://test/index.html")
    }

    @Test("list returns MCPResource with correct mimeType")
    func listReturnsResource() async throws {
        let handler = AppResourceHandler(
            providerId: "ui-app-calc",
            embeddedHTML: ["ui://calc/index.html": "<html/>"]
        )
        let (resources, nextCursor) = try await handler.list(cursor: nil)
        #expect(resources.count == 1)
        #expect(resources[0].uri == "ui://calc/index.html")
        #expect(resources[0].mimeType == appResourceMIMEType)
        #expect(nextCursor == nil)
    }

    @Test("read unknown URI throws ResourceNotFoundError")
    func readUnknownThrows() async {
        let handler = AppResourceHandler(providerId: "empty", embeddedHTML: [:])
        do {
            _ = try await handler.read(uri: "ui://does-not-exist/index.html")
            Issue.record("Expected ResourceNotFoundError to be thrown")
        } catch is ResourceNotFoundError {
            // correct
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - ResourceRegistry integration

    @Test("ResourceRegistry.read returns correct content via AppResourceHandler")
    func registryRead() async throws {
        let registry = ResourceRegistry()
        let handler = AppResourceHandler(
            providerId: "ui-calc",
            embeddedHTML: ["ui://calc/index.html": "<html><body>Calc</body></html>"]
        )
        await registry.registerHandler(handler)

        let content = try await registry.read(uri: "ui://calc/index.html")
        #expect(content.mimeType == appResourceMIMEType)
        #expect(content.text == "<html><body>Calc</body></html>")
    }

    @Test("ResourceRegistry.list includes ui:// resource")
    func registryList() async {
        let registry = ResourceRegistry()
        let handler = AppResourceHandler(
            providerId: "ui-todo",
            embeddedHTML: ["ui://todo/index.html": "<html/>"]
        )
        await registry.registerHandler(handler)

        let (resources, _) = await registry.list()
        #expect(resources.contains { $0.uri == "ui://todo/index.html" })
    }

    // MARK: - MCPServer.registerApp end-to-end

    @Test("MCPServer.registerApp wires handler end-to-end")
    func mcpServerRegisterApp() async throws {
        let server = try MCPServer(config: MCPServerConfig(sourcePath: ""))
        await server.registerApp(
            tool: "my-tool",
            uiUri: "ui://my-tool/index.html",
            uiContent: "<html><body>My Tool UI</body></html>"
        )
        let content = try await server.resources.read(uri: "ui://my-tool/index.html")
        #expect(content.mimeType == appResourceMIMEType)
        #expect(content.text == "<html><body>My Tool UI</body></html>")
    }
}
