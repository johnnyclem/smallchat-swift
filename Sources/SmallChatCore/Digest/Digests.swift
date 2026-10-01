import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - SHA-256 and domain-separated digests

/// SHA-256 of `bytes`, as 64 lower-case hex characters.
public func sha256Hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    SHA256.hash(data: Array(bytes)).map { String(format: "%02x", $0) }.joined()
}

/// A digest input that cannot be used: a part contains U+0000 (the separator).
public struct DigestInputError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// `sha256hex(UTF8(domain) || 0x00 || UTF8(part₁) || 0x00 || … || UTF8(partₙ))`,
/// the suite's domain-separated digest (call digests, proof digests,
/// artifact content hashes). Parts must not contain U+0000.
public func domainDigest(_ domain: String, _ parts: String...) throws -> String {
    try domainDigest(domain, parts: parts)
}

/// `domainDigest(_:_:)` over an array of parts.
public func domainDigest(_ domain: String, parts: [String]) throws -> String {
    var bytes: [UInt8] = []
    for (i, part) in ([domain] + parts).enumerated() {
        if part.unicodeScalars.contains("\u{0}") {
            throw DigestInputError(reason: "domainDigest: part \(i) contains U+0000, which is the separator")
        }
        if i > 0 { bytes.append(0) }
        bytes.append(contentsOf: Array(part.utf8))
    }
    return sha256Hex(bytes)
}

// MARK: - Canonical call digest (smallchat.call.v1)

/// Domain-separation prefix of the call digest.
public let callDigestDomain = "smallchat.call.v1"

/// The canonical call digest of a call to `toolId` with `arguments`
/// (spec/call-digest in @smallchat/core):
///
///     sha256hex(UTF8("smallchat.call.v1") || 0x00 || UTF8(toolId) || 0x00 || UTF8(JCS(arguments)))
///
/// Two calls with the same digest named the same tool with the same
/// arguments, whatever the key order, whitespace or number spelling of the
/// JSON they arrived in. Throws when `toolId` is not
/// `<providerId>/<toolName>`, when `arguments` is not a JSON object, or
/// when it holds a non-finite number.
public func callDigest(toolId: String, arguments: AnyCodableValue) throws -> String {
    _ = try parseToolId(toolId)
    guard case .dict = arguments else {
        throw DigestInputError(reason: "callDigest: arguments must be a JSON object")
    }
    return try domainDigest(callDigestDomain, toolId, canonicalJSON(arguments))
}

/// `callDigest(toolId:arguments:)` for an argument object.
public func callDigest(toolId: String, arguments: [String: AnyCodableValue]) throws -> String {
    try callDigest(toolId: toolId, arguments: .dict(arguments))
}
