import Testing
import Foundation
@testable import SmallChatMCP

@Suite("AuditLog v0.3.0")
struct AuditLogTests {

    @Test("Log entries include chain hash")
    func logEntriesHaveChainHash() async {
        let log = AuditLog()
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        let entries = await log.recent(count: 1)
        #expect(entries.count == 1)
        #expect(entries[0].chainHash != nil)
        #expect(!entries[0].chainHash!.isEmpty)
    }

    @Test("Chain hashes are unique per entry")
    func chainHashesUnique() async {
        let log = AuditLog()
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        await log.log(AuditEntry(method: "tools/list", success: true, durationMs: 5))
        let entries = await log.all()
        #expect(entries.count == 2)
        #expect(entries[0].chainHash != entries[1].chainHash)
    }

    @Test("Chain verification succeeds on untampered log")
    func chainVerificationPasses() async {
        let log = AuditLog()
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        await log.log(AuditEntry(method: "tools/list", success: true, durationMs: 5))
        await log.log(AuditEntry(method: "tools/call", success: false, durationMs: 20, error: "not found"))
        let valid = await log.verifyChain()
        #expect(valid == true)
    }

    @Test("Empty log verifies successfully")
    func emptyLogVerifies() async {
        let log = AuditLog()
        let valid = await log.verifyChain()
        #expect(valid == true)
    }

    @Test("Chain head returns latest hash")
    func chainHeadReturnsLatest() async {
        let log = AuditLog()
        let initial = await log.chainHead()
        #expect(initial.count == 64) // All zeros

        await log.log(AuditEntry(method: "ping", success: true, durationMs: 1))
        let afterLog = await log.chainHead()
        #expect(afterLog != initial)
    }

    @Test("Clear resets chain")
    func clearResetsChain() async {
        let log = AuditLog()
        await log.log(AuditEntry(method: "ping", success: true, durationMs: 1))
        await log.clear()
        let head = await log.chainHead()
        #expect(head == "0000000000000000000000000000000000000000000000000000000000000000")
        #expect(await log.count == 0)
    }

    @Test("Custom HMAC key produces different hashes")
    func customHMACKey() async {
        let log1 = AuditLog(hmacKey: Data("key1".utf8))
        let log2 = AuditLog(hmacKey: Data("key2".utf8))

        let entry = AuditEntry(timestamp: "2025-01-01T00:00:00Z", method: "ping", success: true, durationMs: 1)
        await log1.log(entry)
        await log2.log(entry)

        let hash1 = await log1.chainHead()
        let hash2 = await log2.chainHead()
        #expect(hash1 != hash2)
    }
}
