import Testing
@testable import SmallChatCore

@Suite("SmallChatVersion")
struct SmallChatVersionTests {

    @Test("SmallChatVersion.current is the 1.0.0 release")
    func versionConstant() {
        #expect(SmallChatVersion.current == "1.0.0")
    }
}
