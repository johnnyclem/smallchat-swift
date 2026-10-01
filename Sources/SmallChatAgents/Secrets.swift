import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import Security
#endif

// MARK: - Secrets
//
// The messenger holds two secrets, and neither stands in for the other:
//
//   channel  stenographer → the app's objection-channel bridge
//            (`X-Channel-Secret`; stenographer's SMALLCHAT_CHANNEL_SECRET)
//   notary   the app → stenographer's notarize/dismiss routes
//            (`X-Notary-Secret`; stenographer's STENOGRAPHER_NOTARY_SECRET)
//
// Anyone who can post objections must not be able to mint tombstones, so the
// two are generated separately. Neither is written into messenger.json, which
// any agent can read with its Read tool: on macOS they live in the Keychain,
// elsewhere in 0600 files in a 0700 directory.

public enum MessengerSecret: String, Sendable, CaseIterable {
    case channel = "channel-secret"
    case notary = "notary-secret"

    /// The variable stenographer reads this secret from.
    public var environmentVariable: String {
        switch self {
        case .channel: return "SMALLCHAT_CHANNEL_SECRET"
        case .notary: return "STENOGRAPHER_NOTARY_SECRET"
        }
    }

    var label: String {
        switch self {
        case .channel: return "objection channel secret"
        case .notary: return "notary secret"
        }
    }
}

public enum MessengerSecretError: Error, Equatable, CustomStringConvertible {
    case keychain(status: Int32)
    case file(String)

    public var description: String {
        switch self {
        case .keychain(let status): return "Keychain error \(status)"
        case .file(let reason): return reason
        }
    }
}

public protocol MessengerSecretStore: Sendable {
    func read(_ secret: MessengerSecret) -> String?
    func write(_ value: String, for secret: MessengerSecret) throws
    /// A POSIX shell expression that prints the secret when a command runs,
    /// so commands the user copies never contain the value itself. nil when
    /// a shell can't read this store.
    func shellExpression(for secret: MessengerSecret) -> String?
}

public enum MessengerSecretStores {
    /// The Keychain on macOS; 0600 files in `fileDirectory` elsewhere.
    public static func platformDefault(fileDirectory: URL) -> any MessengerSecretStore {
        #if os(macOS)
        return KeychainSecretStore()
        #else
        return FileSecretStore(directory: fileDirectory)
        #endif
    }
}

/// Secrets for previews and tests; gone when the process exits.
public final class InMemorySecretStore: MessengerSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MessengerSecret: String] = [:]

    public init() {}

    public func read(_ secret: MessengerSecret) -> String? {
        lock.withLock { values[secret] }
    }

    public func write(_ value: String, for secret: MessengerSecret) throws {
        lock.withLock { values[secret] = value }
    }

    public func shellExpression(for secret: MessengerSecret) -> String? { nil }
}

/// One file per secret, mode 0600, in a directory only the user can open.
public struct FileSecretStore: MessengerSecretStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func fileURL(_ secret: MessengerSecret) -> URL {
        directory.appendingPathComponent(secret.rawValue)
    }

    public func read(_ secret: MessengerSecret) -> String? {
        guard let data = try? Data(contentsOf: fileURL(secret)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func write(_ value: String, for secret: MessengerSecret) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw MessengerSecretError.file("Couldn't create \(directory.path): \(error.localizedDescription)")
        }
        // Written beside the target and renamed over it, inside the 0700
        // directory, so a reader never sees a partial or world-readable file.
        let temp = directory.appendingPathComponent(".\(secret.rawValue).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw MessengerSecretError.file("Couldn't write \(temp.path)")
        }
        guard rename(temp.path, fileURL(secret).path) == 0 else {
            try? fm.removeItem(at: temp)
            throw MessengerSecretError.file("Couldn't replace \(fileURL(secret).path)")
        }
    }

    public func shellExpression(for secret: MessengerSecret) -> String? {
        "$(cat \(shellQuoted(fileURL(secret).path)))"
    }
}

#if os(macOS)
/// Generic-password items in the login keychain, one per secret. The app
/// that created an item reads it without a prompt; any other program,
/// including `security` run from an agent's shell, makes macOS ask the user.
public struct KeychainSecretStore: MessengerSecretStore {
    public static let defaultService = "dev.smallchat.messenger"
    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private func itemQuery(_ secret: MessengerSecret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
        ]
    }

    public func read(_ secret: MessengerSecret) -> String? {
        var query = itemQuery(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    public func write(_ value: String, for secret: MessengerSecret) throws {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(itemQuery(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw MessengerSecretError.keychain(status: updated) }
        var item = itemQuery(secret)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "smallchat \(secret.label)"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw MessengerSecretError.keychain(status: added) }
    }

    public func shellExpression(for secret: MessengerSecret) -> String? {
        "$(security find-generic-password -s \(shellQuoted(service)) -a \(shellQuoted(secret.rawValue)) -w)"
    }
}
#endif

/// `s` as one single-quoted POSIX shell word.
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
