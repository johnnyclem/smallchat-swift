import Testing
import Foundation
@testable import SmallChatMCP

private let testAuditKey = Data("audit-test-key".utf8)

@Suite("AuditLog v0.3.0")
struct AuditLogTests {

    @Test("Log entries include chain hash")
    func logEntriesHaveChainHash() async {
        let log = AuditLog(hmacKey: testAuditKey)
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        let entries = await log.recent(count: 1)
        #expect(entries.count == 1)
        #expect(entries[0].chainHash != nil)
        #expect(!entries[0].chainHash!.isEmpty)
    }

    @Test("Chain hashes are unique per entry")
    func chainHashesUnique() async {
        let log = AuditLog(hmacKey: testAuditKey)
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        await log.log(AuditEntry(method: "tools/list", success: true, durationMs: 5))
        let entries = await log.all()
        #expect(entries.count == 2)
        #expect(entries[0].chainHash != entries[1].chainHash)
    }

    @Test("Chain verification succeeds on untampered log")
    func chainVerificationPasses() async {
        let log = AuditLog(hmacKey: testAuditKey)
        await log.log(AuditEntry(method: "initialize", success: true, durationMs: 10))
        await log.log(AuditEntry(method: "tools/list", success: true, durationMs: 5))
        await log.log(AuditEntry(method: "tools/call", success: false, durationMs: 20, error: "not found"))
        let valid = await log.verifyChain()
        #expect(valid == true)
    }

    @Test("Empty log verifies successfully")
    func emptyLogVerifies() async {
        let log = AuditLog(hmacKey: testAuditKey)
        let valid = await log.verifyChain()
        #expect(valid == true)
    }

    @Test("Chain head returns latest hash")
    func chainHeadReturnsLatest() async {
        let log = AuditLog(hmacKey: testAuditKey)
        let initial = await log.chainHead()
        #expect(initial.count == 64) // All zeros

        await log.log(AuditEntry(method: "ping", success: true, durationMs: 1))
        let afterLog = await log.chainHead()
        #expect(afterLog != initial)
    }

    @Test("Clear resets chain")
    func clearResetsChain() async {
        let log = AuditLog(hmacKey: testAuditKey)
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

@Suite("AuditLog integrity")
struct AuditLogIntegrityTests {

    private static let key = Data("test-audit-key-0123456789abcdef".utf8)

    @Test("the chain still verifies after old entries are evicted")
    func verifiesAfterEviction() async {
        let log = AuditLog(maxEntries: 3, hmacKey: Self.key)
        for i in 0..<5 {
            await log.log(AuditEntry(method: "m\(i)", success: true, durationMs: i))
        }
        #expect(await log.count == 3)
        #expect(await log.verifyChain())
    }

    @Test("every field is covered by the chain hash")
    func everyFieldHashed() async {
        let base = AuditEntry(timestamp: "2026-01-01T00:00:00Z", method: "tools/call", sessionId: "s", clientId: "a", success: false, durationMs: 1, error: "boom")
        let otherClient = AuditEntry(timestamp: "2026-01-01T00:00:00Z", method: "tools/call", sessionId: "s", clientId: "b", success: false, durationMs: 1, error: "boom")
        let otherError = AuditEntry(timestamp: "2026-01-01T00:00:00Z", method: "tools/call", sessionId: "s", clientId: "a", success: false, durationMs: 1, error: "fine")
        var heads: Set<String> = []
        for entry in [base, otherClient, otherError] {
            let log = AuditLog(hmacKey: Self.key)
            await log.log(entry)
            heads.insert(await log.chainHead())
        }
        #expect(heads.count == 3)
    }
}
