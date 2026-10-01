import Testing
import SmallChatAgents

/// DOC-AGENTS-REEXPORT: this file imports SmallChatAgents and nothing else,
/// like code written against 0.6, when the channel bridge types lived there.
/// It compiles only because SmallChatAgents re-exports SmallChatChannel.
@Suite("SmallChatAgents re-exports the channel bridge")
struct ChannelReexportTests {
    @Test("the bridge types are visible through import SmallChatAgents")
    func bridgeTypesVisible() {
        #expect(!ChannelBridgeProtocol.generateSecret().isEmpty)
        #expect(ChannelBridgeProtocol.constantTimeEqual("a", "a"))
        _ = ChannelInboundEvent.self
        _ = ChannelBridgeResponse.self
        _ = ChannelBridgeServer.self
    }
}
