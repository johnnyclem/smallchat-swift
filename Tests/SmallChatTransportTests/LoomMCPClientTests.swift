import Testing
@testable import SmallChatTransport

@Suite("LoomMCPClient")
struct LoomMCPClientTests {

    @Test("Provider id and known-tool list match the bundled manifest")
    func knownInventory() {
        #expect(LoomMCPClient.providerId == "loom")
        #expect(LoomMCPClient.knownToolNames.count == 28)
        #expect(LoomMCPClient.knownToolNames.contains("loom_find_importers"))
        #expect(LoomMCPClient.knownToolNames.contains("loom_get_topology"))
    }

    @Test("Default command is the npx launcher with the loom-mcp package")
    func defaultLaunch() {
        #expect(LoomMCPClient.defaultCommand == "npx")
        #expect(LoomMCPClient.defaultArgs == ["-y", "@loom-mcp/server"])
    }

    @Test("Detection probe returns one of present / missing / unknown")
    func detectionProbe() {
        let result = LoomDetection.probe()
        // Any of the three is acceptable; we just want the probe to not crash.
        let acceptable: Set<LoomDetection.Result> = [.present, .missing, .unknown]
        #expect(acceptable.contains(result))
    }
}
