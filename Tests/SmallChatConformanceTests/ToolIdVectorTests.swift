import Foundation
import Testing
import SmallChatCore

/// spec/tool-id/vectors.json (smallchat.tool-id.v1): how canonical tool ids
/// split, which are refused, and each tool's aggregate MCP name.
@Suite("Conformance: canonical tool id (spec/tool-id)")
struct ToolIdVectorTests {
    static let spec = try! SpecFixtures.json("tool-id/vectors.json")

    @Test("the vectors are smallchat.tool-id.v1")
    func version() {
        #expect(Self.spec["version"]?.stringValue == "smallchat.tool-id.v1")
    }

    @Test("every valid id splits, round-trips and maps to its aggregate name", arguments: ToolIdVectorTests.spec["valid"]!.arrayValue)
    func valid(_ v: AnyCodableValue) throws {
        let id = try #require(v["id"]?.stringValue)
        let providerId = try #require(v["providerId"]?.stringValue)
        let toolName = try #require(v["toolName"]?.stringValue)
        let parsed = try parseToolId(id)
        #expect(parsed.providerId == providerId)
        #expect(parsed.toolName == toolName)
        #expect(try makeToolId(providerId: providerId, toolName: toolName) == id)
        #expect(mcpAggregateName(providerId: providerId, toolName: toolName) == v["aggregateName"]?.stringValue)
    }

    @Test("every invalid id is refused", arguments: ToolIdVectorTests.spec["invalid"]!.arrayValue)
    func invalid(_ v: AnyCodableValue) throws {
        let id = try #require(v["id"]?.stringValue)
        #expect(throws: InvalidToolIdError.self, "\(v["reason"]?.stringValue ?? "")") {
            _ = try parseToolId(id)
        }
    }
}
