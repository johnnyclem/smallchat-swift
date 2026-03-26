import Testing
import Foundation
@testable import SmallChatChannel

@Suite("SenderGate")
struct SenderGateTests {

    // MARK: - Allowlist check

    @Test("Open mode allows all senders when allowlist is empty")
    func openModeAllowsAll() async {
        let gate = SenderGate()
        #expect(await gate.check("anyone") == true)
        #expect(await gate.check(nil) == true)
        #expect(await gate.isEnabled == false)
    }

    @Test("Allowlist blocks unlisted sender")
    func allowlistBlocksUnlisted() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("bob") == false)
        #expect(await gate.isEnabled == true)
    }

    @Test("Allowlist rejects nil sender when enabled")
    func rejectsNilWhenEnabled() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check(nil) == false)
    }

    @Test("Allowlist rejects empty string sender when enabled")
    func rejectsEmptyStringWhenEnabled() async {
        let gate = SenderGate(allowlist: ["alice"])
        #expect(await gate.check("") == false)
    }

    @Test("Sender check is case-insensitive")
    func caseInsensitiveCheck() async {
        let gate = SenderGate(allowlist: ["Alice"])
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("ALICE") == true)
        #expect(await gate.check("  Alice  ") == true)
    }

    // MARK: - Management

    @Test("Allow and revoke senders dynamically")
    func allowAndRevoke() async {
        let gate = SenderGate(allowlist: ["alice"])
        await gate.allow("bob")
        #expect(await gate.check("bob") == true)

        await gate.revoke("bob")
        #expect(await gate.check("bob") == false)
    }

    @Test("getAllowed returns current allowlist")
    func getAllowed() async {
        let gate = SenderGate(allowlist: ["alice", "bob"])
        let allowed = Set(await gate.getAllowed())
        #expect(allowed == ["alice", "bob"])
    }

    @Test("Allow ignores empty strings")
    func allowIgnoresEmpty() async {
        let gate = SenderGate(allowlist: ["alice"])
        await gate.allow("")
        await gate.allow("   ")
        let allowed = await gate.getAllowed()
        #expect(allowed.count == 1)
    }

    // MARK: - Pairing flow

    @Test("Pairing flow adds sender to allowlist on success")
    func pairingFlowSuccess() async {
        let gate = SenderGate(allowlist: ["admin"])
        let code = await gate.generatePairingCode(for: "newuser")
        let result = await gate.completePairing(senderId: "newuser", code: code)
        #expect(result == true)
        #expect(await gate.check("newuser") == true)
    }

    @Test("Pairing rejects wrong code")
    func pairingRejectsWrongCode() async {
        let gate = SenderGate(allowlist: ["admin"])
        _ = await gate.generatePairingCode(for: "newuser")
        let result = await gate.completePairing(senderId: "newuser", code: "000000")
        #expect(result == false)
        #expect(await gate.check("newuser") == false)
    }

    @Test("Pairing rejects unknown sender")
    func pairingRejectsUnknownSender() async {
        let gate = SenderGate(allowlist: ["admin"])
        let result = await gate.completePairing(senderId: "nobody", code: "aabbcc")
        #expect(result == false)
    }

    @Test("Pairing code is case-insensitive on sender")
    func pairingCaseInsensitive() async {
        let gate = SenderGate(allowlist: ["admin"])
        let code = await gate.generatePairingCode(for: "NewUser")
        let result = await gate.completePairing(senderId: "newuser", code: code)
        #expect(result == true)
    }

    // MARK: - File reload

    @Test("Reload from allowlist file")
    func reloadAllowlistFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_allowlist_\(UUID().uuidString).txt").path

        let content = """
        # Comment line
        alice
        bob

        charlie
        """
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let gate = SenderGate(allowlistFile: filePath)
        #expect(await gate.check("alice") == true)
        #expect(await gate.check("bob") == true)
        #expect(await gate.check("charlie") == true)
        #expect(await gate.check("eve") == false)
    }

    @Test("Reload merges file entries with programmatic entries")
    func reloadMergesEntries() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_allowlist_merge_\(UUID().uuidString).txt").path

        try "fileuser".write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let gate = SenderGate(allowlist: ["memuser"], allowlistFile: filePath)
        #expect(await gate.check("memuser") == true)
        #expect(await gate.check("fileuser") == true)
    }
}
