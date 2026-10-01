// MARK: - AuditLog — In-memory ring buffer of MCP request audit entries

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Audit Entry

/// A structured log entry for an MCP operation.
///
/// Each entry carries a `chainHash`: HMAC-SHA256, under the log's key, of the
/// previous entry's hash and the canonical JSON of every other field of this
/// entry. Changing, removing or reordering a retained entry breaks the chain.
public struct AuditEntry: Sendable, Codable, Equatable {
    public let timestamp: String
    public let method: String
    public let sessionId: String?
    public let clientId: String?
    public let success: Bool
    public let durationMs: Int
    public let error: String?
    /// HMAC-SHA256 hash chain link, hex-encoded. Set by `AuditLog.log(_:)`.
    public let chainHash: String?

    public init(
        timestamp: String? = nil,
        method: String,
        sessionId: String? = nil,
        clientId: String? = nil,
        success: Bool,
        durationMs: Int,
        error: String? = nil,
        chainHash: String? = nil
    ) {
        self.timestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
        self.method = method
        self.sessionId = sessionId
        self.clientId = clientId
        self.success = success
        self.durationMs = durationMs
        self.error = error
        self.chainHash = chainHash
    }

    /// Canonical JSON (sorted keys) of every field except `chainHash`.
    var hashContent: Data {
        struct Fields: Encodable {
            let timestamp: String
            let method: String
            let sessionId: String?
            let clientId: String?
            let success: Bool
            let durationMs: Int
            let error: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = Fields(
            timestamp: timestamp, method: method, sessionId: sessionId, clientId: clientId,
            success: success, durationMs: durationMs, error: error
        )
        return (try? encoder.encode(fields)) ?? Data()
    }

    func withChainHash(_ hash: String) -> AuditEntry {
        AuditEntry(
            timestamp: timestamp, method: method, sessionId: sessionId, clientId: clientId,
            success: success, durationMs: durationMs, error: error, chainHash: hash
        )
    }
}

// MARK: - AuditLog Actor

/// In-memory ring buffer of recent MCP request audit entries.
///
/// Capped at maxEntries (default 10,000) to bound memory usage.
/// Supports querying by method, session, success status, and time range.
///
/// The entries form an HMAC-SHA256 hash chain under a key the caller
/// supplies (there is no built-in key: a published key would let anyone
/// recompute a valid chain after editing entries). The chain detects edits
/// to retained entries by someone without the key. It does not survive the
/// process: the log is in memory only.
public actor AuditLog {

    private static let genesisHash = String(repeating: "0", count: 64)

    private var entries: [AuditEntry] = []
    private let maxEntries: Int
    private var lastHash: String = AuditLog.genesisHash
    /// The hash that precedes the first retained entry (the last evicted
    /// entry's hash), so the retained window still verifies after eviction.
    private var anchorHash: String = AuditLog.genesisHash
    private let hmacKey: SymmetricKey

    /// - Parameters:
    ///   - maxEntries: Entries kept before the oldest are evicted.
    ///   - hmacKey: Secret key for the hash chain. Must not be empty; use
    ///     `AuditLog.generateKey()` for a fresh random key.
    public init(maxEntries: Int = 10_000, hmacKey: Data) {
        precondition(!hmacKey.isEmpty, "AuditLog needs a non-empty HMAC key")
        self.maxEntries = max(1, maxEntries)
        self.hmacKey = SymmetricKey(data: hmacKey)
    }

    /// 32 random bytes, suitable as an audit chain key.
    public static func generateKey() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    /// Log a new audit entry, computing its chain hash.
    public func log(_ entry: AuditEntry) {
        let hash = chainHash(previous: lastHash, entry: entry)
        lastHash = hash
        entries.append(entry.withChainHash(hash))
        if entries.count > maxEntries {
            let evicted = entries.count - maxEntries
            anchorHash = entries[evicted - 1].chainHash ?? anchorHash
            entries.removeFirst(evicted)
        }
    }

    /// Verify the integrity of the retained entries.
    ///
    /// Returns `true` if every retained entry's hash matches its content and
    /// its predecessor's hash, starting from the hash of the last evicted
    /// entry (or the zero hash if nothing was evicted).
    public func verifyChain() -> Bool {
        var previousHash = anchorHash
        for entry in entries {
            guard entry.chainHash == chainHash(previous: previousHash, entry: entry) else { return false }
            previousHash = entry.chainHash ?? ""
        }
        return previousHash == lastHash
    }

    /// Get the most recent entries.
    public func recent(count: Int = 100) -> [AuditEntry] {
        Array(entries.suffix(count))
    }

    /// Get all entries (up to maxEntries).
    public func all() -> [AuditEntry] {
        entries
    }

    /// Get entries filtered by method.
    public func filter(method: String) -> [AuditEntry] {
        entries.filter { $0.method == method }
    }

    /// Get entries filtered by session ID.
    public func filter(sessionId: String) -> [AuditEntry] {
        entries.filter { $0.sessionId == sessionId }
    }

    /// Get entries filtered by success status.
    public func filter(success: Bool) -> [AuditEntry] {
        entries.filter { $0.success == success }
    }

    /// Get entries after a given ISO 8601 timestamp.
    public func filter(after timestamp: String) -> [AuditEntry] {
        entries.filter { $0.timestamp >= timestamp }
    }

    /// Get the total number of logged entries.
    public var count: Int { entries.count }

    /// Clear all entries and reset the chain.
    public func clear() {
        entries.removeAll()
        lastHash = Self.genesisHash
        anchorHash = Self.genesisHash
    }

    /// Get the current chain head hash.
    public func chainHead() -> String {
        lastHash
    }

    private func chainHash(previous: String, entry: AuditEntry) -> String {
        var message = Data(previous.utf8)
        message.append(UInt8(ascii: "|"))
        message.append(entry.hashContent)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: hmacKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
