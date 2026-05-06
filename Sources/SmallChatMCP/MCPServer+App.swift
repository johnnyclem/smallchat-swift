import SmallChatCore

// MARK: - MCPServer App Registration

extension MCPServer {

    /// Register an App with the MCP server.
    ///
    /// Creates an `AppResourceHandler` for the given UI content and registers it
    /// with the resource registry.  After this call, MCP clients can call
    /// `resources/read` with `uiUri` to receive the HTML with MIME type
    /// `text/html;profile=mcp-app`.
    ///
    /// - Parameters:
    ///   - tool: Tool name for the app (used as `providerId`).
    ///   - uiUri: The `ui://` URI under which the content is served, e.g. `"ui://my-app/index.html"`.
    ///   - uiContent: Raw HTML string to serve.
    public func registerApp(tool: String, uiUri: String, uiContent: String) async {
        let handler = AppResourceHandler(
            providerId: tool,
            embeddedHTML: [uiUri: uiContent]
        )
        await resources.registerHandler(handler)
    }
}
