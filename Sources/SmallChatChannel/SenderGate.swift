// MARK: - Sender Gate
// Allowlist-based sender identity gating for channel events.
// Primary defense against prompt injection via channel events.

import Foundation
#if canImport(Security)
import Security
#endif

/// Allowlist-based sender identity gating for channel events.
///
/// Ensures that only authorized senders can inject messages into the channel.
/// Supports:
///   - In-memory allowlist (programmatic)
///   - File-based allowlist (one sender per line, reloadable)
///   - Optional pairing code flow for bootstrap
///   - Identity validation (v0.3.0): length limits, character restrictions
///   - Max sender limit (v0.3.0): prevents unbounded allowlist growth
public actor SenderGate {
    private var allowlist: Set<String> = []
    private let allowlistFilePath: String?
    private var pendingPairings: [String: PendingPairing] = [:]

    /// Pairing code expiry duration in seconds (5 minutes).
    private let pairingExpirySeconds: TimeInterval = 5 * 60

    /// Maximum number of allowed senders (v0.3.0). 0 = unlimited.
    private let maxSenders: Int

    /// Maximum sender identity length in characters (v0.3.0).
    public static let maxSenderLength: Int = 128

    /// Minimum sender identity length in characters (v0.3.0).
    public static let minSenderLength: Int = 1

    /// Allowed characters in sender identities (v0.3.0): alphanumerics, hyphens, underscores, dots, @.
    private static let senderIdentityPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._@\\-]+$")

    private struct PendingPairing {
        let code: String
        let expiresAt: Date
    }

    public init(allowlist: [String]? = nil, allowlistFile: String? = nil, maxSenders: Int = 500) {
        self.allowlistFilePath = allowlistFile
        self.maxSenders = maxSenders

        if let senders = allowlist {
            for sender in senders {
                let normalized = sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty && SenderGate.isValidSenderIdentity(normalized) {
                    self.allowlist.insert(normalized)
                }
            }
        }

        if allowlistFile != nil {
            loadAllowlistFile()
        }
    }

    // MARK: - Identity Validation (v0.3.0)

    /// Validate a sender identity string.
    ///
    /// Rules:
    /// - Length: 1–128 characters
    /// - Characters: alphanumerics, hyphens, underscores, dots, @
    /// - No control characters or whitespace
    public static func isValidSenderIdentity(_ sender: String) -> Bool {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minSenderLength, trimmed.count <= maxSenderLength else {
            return false
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return senderIdentityPattern.firstMatch(in: trimmed, range: range) != nil
    }

    // MARK: - Checking

    /// Check if a sender is allowed to send messages.
    /// Returns true if the allowlist is empty (open mode) or sender is listed.
    public func check(_ sender: String?) -> Bool {
        // If no allowlist configured, gate is open
        if allowlist.isEmpty {
            return true
        }

        guard let sender, !sender.isEmpty else { return false }
        return allowlist.contains(sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether gating is enabled (allowlist has entries).
    public var isEnabled: Bool {
        !allowlist.isEmpty
    }

    // MARK: - Management

    /// Add a sender to the allowlist.
    ///
    /// v0.3.0: Validates identity format and enforces max sender limit.
    /// Returns false if the identity is invalid or the limit is reached.
    @discardableResult
    public func allow(_ sender: String) -> Bool {
        let normalized = sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard SenderGate.isValidSenderIdentity(normalized) else { return false }
        if maxSenders > 0 && allowlist.count >= maxSenders && !allowlist.contains(normalized) {
            return false
        }
        allowlist.insert(normalized)
        return true
    }

    /// Remove a sender from the allowlist.
    public func revoke(_ sender: String) {
        let normalized = sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        allowlist.remove(normalized)
    }

    /// Get all allowed senders.
    public func getAllowed() -> [String] {
        Array(allowlist)
    }

    // MARK: - Pairing

    /// Generate a pairing code for a new sender.
    /// The sender must reply with this code to be added to the allowlist.
    /// Returns the pairing code (6 hex characters). Expires after 5 minutes.
    public func generatePairingCode(for senderId: String) -> String {
        let normalized = senderId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let code = generateHexCode(length: 6)
        let pairing = PendingPairing(
            code: code,
            expiresAt: Date().addingTimeInterval(pairingExpirySeconds)
        )
        pendingPairings[normalized] = pairing
        return code
    }

    /// Attempt to complete a pairing by verifying the code.
    /// If successful, adds the sender to the allowlist.
    ///
    /// v0.3.0: Uses constant-time comparison for pairing codes to prevent
    /// timing side-channel attacks.
    public func completePairing(senderId: String, code: String) -> Bool {
        let normalized = senderId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pending = pendingPairings[normalized] else { return false }

        if Date() > pending.expiresAt {
            pendingPairings.removeValue(forKey: normalized)
            return false
        }

        let providedCode = code.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard constantTimeEqual(pending.code, providedCode) else {
            return false
        }

        pendingPairings.removeValue(forKey: normalized)

        // Enforce max senders on pairing completion too
        if maxSenders > 0 && allowlist.count >= maxSenders {
            return false
        }

        allowlist.insert(normalized)
        return true
    }

    /// Get the current sender count (v0.3.0).
    public var senderCount: Int {
        allowlist.count
    }

    // MARK: - File Loading

    /// Reload the allowlist from the configured file.
    public func reloadAllowlistFile() {
        loadAllowlistFile()
    }

    // MARK: - Private

    private func loadAllowlistFile() {
        guard let path = allowlistFilePath else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            for line in lines {
                let normalized = line.lowercased()
                if SenderGate.isValidSenderIdentity(normalized) {
                    allowlist.insert(normalized)
                }
            }
        } catch {
            // File read error -- non-critical, silently ignore
        }
    }

    /// Generate a random hex string of the given length.
    private func generateHexCode(length: Int) -> String {
        let byteCount = (length + 1) / 2
        var bytes = [UInt8](repeating: 0, count: byteCount)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        #else
        // Linux: read from /dev/urandom
        if let fh = FileHandle(forReadingAtPath: "/dev/urandom") {
            let data = fh.readData(ofLength: byteCount)
            fh.closeFile()
            for (i, byte) in data.enumerated() where i < byteCount {
                bytes[i] = byte
            }
        } else {
            // Fallback: use system random
            for i in 0..<byteCount {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        #endif
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    /// Constant-time string comparison to prevent timing attacks (v0.3.0).
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }
}
