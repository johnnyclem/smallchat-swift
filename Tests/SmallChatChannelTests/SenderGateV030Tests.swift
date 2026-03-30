import Testing
import Foundation
@testable import SmallChatChannel

@Suite("SenderGate v0.3.0")
struct SenderGateV030Tests {

    // MARK: - Identity Validation

    @Test("Valid sender identities pass validation")
    func validIdentities() {
        #expect(SenderGate.isValidSenderIdentity("alice") == true)
        #expect(SenderGate.isValidSenderIdentity("user123") == true)
        #expect(SenderGate.isValidSenderIdentity("user.name") == true)
        #expect(SenderGate.isValidSenderIdentity("user_name") == true)
        #expect(SenderGate.isValidSenderIdentity("user-name") == true)
        #expect(SenderGate.isValidSenderIdentity("user@example.com") == true)
    }

    @Test("Invalid sender identities fail validation")
    func invalidIdentities() {
        #expect(SenderGate.isValidSenderIdentity("") == false)
        #expect(SenderGate.isValidSenderIdentity("user name") == false) // spaces
        #expect(SenderGate.isValidSenderIdentity("user<script>") == false) // angle brackets
        #expect(SenderGate.isValidSenderIdentity("user\nnewline") == false) // newline
        #expect(SenderGate.isValidSenderIdentity("user\0null") == false) // null byte
    }

    @Test("Sender identity respects max length")
    func maxLengthEnforced() {
        let longId = String(repeating: "a", count: SenderGate.maxSenderLength)
        #expect(SenderGate.isValidSenderIdentity(longId) == true)

        let tooLong = String(repeating: "a", count: SenderGate.maxSenderLength + 1)
        #expect(SenderGate.isValidSenderIdentity(tooLong) == false)
    }

    // MARK: - Max Sender Limit

    @Test("Max sender limit prevents unbounded growth")
    func maxSenderLimit() async {
        let gate = SenderGate(maxSenders: 3)
        let r1 = await gate.allow("user1")
        let r2 = await gate.allow("user2")
        let r3 = await gate.allow("user3")
        #expect(r1 == true)
        #expect(r2 == true)
        #expect(r3 == true)

        // Fourth should fail
        let r4 = await gate.allow("user4")
        #expect(r4 == false)
        #expect(await gate.senderCount == 3)
    }

    @Test("Allow returns false for invalid identity")
    func allowRejectsInvalid() async {
        let gate = SenderGate(maxSenders: 10)
        let result = await gate.allow("user with spaces")
        #expect(result == false)
    }

    @Test("Allow returns true for re-adding existing sender")
    func allowAcceptsExisting() async {
        let gate = SenderGate(allowlist: ["alice"], maxSenders: 1)
        // Already at limit but alice is already in the list
        let result = await gate.allow("alice")
        #expect(result == true)
    }

    // MARK: - Constant-time Pairing

    @Test("Pairing still works with constant-time comparison")
    func pairingWorksWithConstantTime() async {
        let gate = SenderGate(allowlist: ["admin"], maxSenders: 10)
        let code = await gate.generatePairingCode(for: "newuser")
        let result = await gate.completePairing(senderId: "newuser", code: code)
        #expect(result == true)
        #expect(await gate.check("newuser") == true)
    }

    @Test("Pairing respects max sender limit")
    func pairingRespectsMaxSenders() async {
        let gate = SenderGate(allowlist: ["admin"], maxSenders: 1)
        let code = await gate.generatePairingCode(for: "newuser")
        // Already at limit with "admin"
        let result = await gate.completePairing(senderId: "newuser", code: code)
        #expect(result == false)
    }
}
