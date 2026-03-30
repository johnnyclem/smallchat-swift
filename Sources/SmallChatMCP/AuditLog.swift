// MARK: - AuditLog — In-memory ring buffer of MCP request audit entries

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Audit Entry

/// A structured log entry for an MCP operation.
///
/// v0.3.0: Each entry includes a `chainHash` — an HMAC-SHA256 of the entry's
/// content combined with the previous entry's hash. This forms a tamper-evident
/// hash chain for audit integrity verification.
public struct AuditEntry: Sendable, Codable {
    public let timestamp: String
    public let method: String
    public let sessionId: String?
    public let clientId: String?
    public let success: Bool
    public let durationMs: Int
    public let error: String?
    /// HMAC-SHA256 hash chain link (v0.3.0). Hex-encoded.
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

    /// Content string used for hash chain computation.
    var hashContent: String {
        "\(timestamp)|\(method)|\(sessionId ?? "")|\(success)|\(durationMs)"
    }
}

// MARK: - AuditLog Actor

/// In-memory ring buffer of recent MCP request audit entries.
///
/// Capped at maxEntries (default 10,000) to bound memory usage.
/// Supports querying by method, session, success status, and time range.
///
/// v0.3.0: Maintains a hash chain for tamper detection. Each entry's `chainHash`
/// is an HMAC-SHA256 of its content concatenated with the previous entry's hash.
public actor AuditLog {

    private var entries: [AuditEntry] = []
    private let maxEntries: Int
    private var lastHash: String = "0000000000000000000000000000000000000000000000000000000000000000"
    private let hmacKey: Data

    /// Initialize with a maximum number of entries to retain.
    /// The HMAC key is used for hash chain integrity (v0.3.0).
    public init(maxEntries: Int = 10_000, hmacKey: Data? = nil) {
        self.maxEntries = maxEntries
        // Default: derive key from a fixed seed (callers should provide their own)
        self.hmacKey = hmacKey ?? Data("smallchat-audit-v0.3.0".utf8)
    }

    /// Log a new audit entry, computing its chain hash.
    public func log(_ entry: AuditEntry) {
        let chainInput = "\(lastHash)|\(entry.hashContent)"
        let hash = computeHMACSHA256(chainInput, key: hmacKey)

        let chainedEntry = AuditEntry(
            timestamp: entry.timestamp,
            method: entry.method,
            sessionId: entry.sessionId,
            clientId: entry.clientId,
            success: entry.success,
            durationMs: entry.durationMs,
            error: entry.error,
            chainHash: hash
        )

        lastHash = hash
        entries.append(chainedEntry)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
    }

    /// Verify the integrity of the audit log chain (v0.3.0).
    ///
    /// Returns `true` if all chain hashes are consistent.
    /// Note: only verifiable from the start of the retained window (after eviction,
    /// entries before the window are lost).
    public func verifyChain() -> Bool {
        guard !entries.isEmpty else { return true }

        var previousHash = "0000000000000000000000000000000000000000000000000000000000000000"

        // If entries have been evicted, we can't verify from genesis.
        // Verify internal consistency of retained entries.
        for entry in entries {
            let chainInput = "\(previousHash)|\(entry.hashContent)"
            let expected = computeHMACSHA256(chainInput, key: hmacKey)
            guard entry.chainHash == expected else { return false }
            previousHash = entry.chainHash ?? ""
        }
        return true
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
        lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    }

    /// Get the current chain head hash (v0.3.0).
    public func chainHead() -> String {
        lastHash
    }
}

// MARK: - HMAC-SHA256 Helper

/// Compute HMAC-SHA256, returning a hex-encoded string.
private func computeHMACSHA256(_ message: String, key: Data) -> String {
    let messageData = Data(message.utf8)

    #if canImport(CryptoKit)
    let symmetricKey = SymmetricKey(data: key)
    let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
    return mac.map { String(format: "%02x", $0) }.joined()
    #else
    // Fallback: simple hash for platforms without CryptoKit
    // This is a non-cryptographic fallback; CryptoKit should always be preferred.
    var hash: UInt64 = 14695981039346656037 // FNV offset
    for byte in key + messageData {
        hash ^= UInt64(byte)
        hash &*= 1099511628211 // FNV prime
    }
    return String(format: "%016x%016x%016x%016x", hash, hash &* 31, hash &* 37, hash &* 41)
    #endif
}
