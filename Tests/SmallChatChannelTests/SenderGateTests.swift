import Foundation
import Testing
@testable import SmallChatChannel

@Suite("SenderGate")
struct SenderGateTests {

    // MARK: - Allowlist Check

    @Test("Open mode (empty allowlist) allows any sender")
    func openModeAllowsAll() async {
        let gate = SenderGate()
        #expect(await gate.check("anyone") == true)
        #expect(await gate.check(nil) == true)
        #expect(await gate.isEnabled == false)
    }

    @Test("Allowlist blocks unknown sender")
    func allowlistBlocksUnknown() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("bob") == false)
        #expect(await gate.isEnabled == true)
    }

    @Test("Allowlist allows listed sender")
    func allowlistAllowsListed() async {
        let gate = SenderGate(allowlist: ["alice", "bob"])
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("bob") == true)
    }

    @Test("Check is case-insensitive")
    func checkIsCaseInsensitive() async {
        let gate = SenderGate(allowlist: ["Alice"])
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("ALICE") == true)
        #expect(await gate.check("Alice") == true)
    }

    @Test("Check trims whitespace")
    func checkTrimsWhitespace() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("  alice  ") == true)
    }

    @Test("Nil sender rejected when allowlist is active")
    func nilSenderRejected() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check(nil) == false)
    }

    @Test("Empty string sender rejected when allowlist is active")
    func emptySenderRejected() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("") == false)
    }

    // MARK: - Allow / Revoke

    @Test("allow adds sender to allowlist")
    func allowAddsSender() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("bob") == false)

        await gate.allow("bob")
        #expect(await gate.check("bob") == true)
    }

    @Test("revoke removes sender from allowlist")
    func revokeRemovesSender() async {
        let gate = SenderGate(allowlist: ["alice", "bob"])
        #expect(await gate.check("bob") == true)

        await gate.revoke("bob")
        #expect(await gate.check("bob") == false)
    }

    @Test("getAllowed returns all senders")
    func getAllowedReturnsAll() async {
        let gate = SenderGate(allowlist: ["alice", "bob"])
        let allowed = await gate.getAllowed()
        #expect(allowed.sorted() == ["alice", "bob"])
    }

    @Test("allow ignores empty strings")
    func allowIgnoresEmpty() async {
        let gate = SenderGate()
        await gate.allow("")
        await gate.allow("   ")
        #expect(await gate.isEnabled == false)
    }

    // MARK: - Pairing Flow

    @Test("Pairing code generates 6-character hex string")
    func pairingCodeFormat() async {
        let gate = SenderGate(allowlist: ["admin"])
        let code = await gate.generatePairingCode(for: "newuser")
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isHexDigit })
    }

    @Test("Correct pairing code adds sender to allowlist")
    func correctPairingAdds() async {
        let gate = SenderGate(allowlist: ["admin"])
        let code = await gate.generatePairingCode(for: "newuser")

        let success = await gate.completePairing(senderId: "newuser", code: code)
        #expect(success == true)
        #expect(await gate.check("newuser") == true)
    }

    @Test("Wrong pairing code does not add sender")
    func wrongPairingFails() async {
        let gate = SenderGate(allowlist: ["admin"])
        _ = await gate.generatePairingCode(for: "newuser")

        let success = await gate.completePairing(senderId: "newuser", code: "wrong!")
        #expect(success == false)
        #expect(await gate.check("newuser") == false)
    }

    @Test("Pairing for unknown sender returns false")
    func pairingForUnknownFails() async {
        let gate = SenderGate(allowlist: ["admin"])
        let success = await gate.completePairing(senderId: "nobody", code: "abcdef")
        #expect(success == false)
    }

    @Test("Pairing is case-insensitive on sender ID")
    func pairingCaseInsensitive() async {
        let gate = SenderGate(allowlist: ["admin"])
        let code = await gate.generatePairingCode(for: "NewUser")
        let success = await gate.completePairing(senderId: "newuser", code: code)
        #expect(success == true)
    }

    // MARK: - File Reload

    @Test("Loads allowlist from file")
    func loadsFromFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("test_allowlist_\(UUID().uuidString).txt").path

        let content = """
        alice
        bob
        # this is a comment
        charlie
        """
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let gate = SenderGate(allowlistFile: filePath)
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("bob") == true)
        #expect(await gate.check("charlie") == true)
        #expect(await gate.check("dave") == false)
    }

    @Test("reloadAllowlistFile picks up new entries")
    func reloadPicksUpNewEntries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let filePath = tempDir.appendingPathComponent("test_allowlist_reload_\(UUID().uuidString).txt").path

        try "alice".write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let gate = SenderGate(allowlistFile: filePath)
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("bob") == false)

        // Update file and reload
        try "alice\nbob".write(toFile: filePath, atomically: true, encoding: .utf8)
        await gate.reloadAllowlistFile()
        #expect(await gate.check("bob") == true)
    }

    @Test("Missing file does not crash")
    func missingFileDoesNotCrash() async {
        let gate = SenderGate(allowlistFile: "/nonexistent/path/allowlist.txt")
        // Should gracefully handle missing file — open mode since allowlist is empty
        #expect(await gate.check("anyone") == true)
    }
}
