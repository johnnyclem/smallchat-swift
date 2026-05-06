import Foundation
import SmallChatCore

// MARK: - AppResourceHandler

/// MCP `ResourceHandler` that serves embedded HTML blobs under `ui://` URIs.
///
/// Registered with `ResourceRegistry` by `MCPServer.registerApp(tool:uiUri:uiContent:)`.
/// When an MCP client calls `resources/read` with a `ui://` URI, this handler returns
/// the HTML content with MIME type `text/html;profile=mcp-app`.
public struct AppResourceHandler: ResourceHandler, Sendable {
    public let providerId: String
    private let embeddedHTML: [String: String]  // "ui://appId/index.html" → HTML

    public init(providerId: String, embeddedHTML: [String: String]) {
        self.providerId = providerId
        self.embeddedHTML = embeddedHTML
    }

    // MARK: - ResourceHandler

    public func list(cursor: String?) async throws
        -> (resources: [MCPResource], nextCursor: String?) {
        let resources = embeddedHTML.keys.sorted().map { uri in
            MCPResource(
                uri: uri,
                name: uri,
                description: "App UI resource",
                mimeType: appResourceMIMEType,
                providerId: providerId
            )
        }
        return (resources: resources, nextCursor: nil)
    }

    public func read(uri: String) async throws -> MCPResourceContent {
        guard let html = embeddedHTML[uri] else {
            throw ResourceNotFoundError(uri: uri)
        }
        return MCPResourceContent(
            uri: uri,
            mimeType: appResourceMIMEType,
            text: html
        )
    }
}

// MARK: - Constants

/// MIME type returned for all `ui://` resources.
public let appResourceMIMEType = "text/html;profile=mcp-app"
