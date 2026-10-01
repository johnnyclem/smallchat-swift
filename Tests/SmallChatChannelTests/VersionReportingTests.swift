import Testing
import Foundation
import SmallChatCore
@testable import SmallChatChannel

/// Every MCP peer of the channel server must see the package version, not a
/// stale hardcoded one (it reported "0.3.0" while the package was 0.6.0).
@Suite("Channel server version")
struct VersionReportingTests {

    @Test("initialize reports SmallChatVersion.current as serverInfo.version")
    func initializeReportsPackageVersion() async throws {
        let server = ChannelServer(config: ChannelServerConfig(channelName: "test"))
        await server.start()
        let outbound = await server.outboundMessages

        await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)

        var iterator = outbound.makeAsyncIterator()
        let line = try #require(await iterator.next())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["version"] as? String == SmallChatVersion.current)
        await server.shutdown()
    }
}
