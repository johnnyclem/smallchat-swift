import Foundation

/// The universal transport protocol.
///
/// Every transport implementation (HTTP, MCP stdio/SSE, local function) conforms
/// to this protocol. The runtime dispatches through it without knowing the
/// underlying protocol, keeping tool resolution and execution cleanly separated.
///
/// Mirrors the TypeScript `ITransport` interface.
public protocol Transport: Sendable {

    /// Unique identifier for this transport instance.
    var id: String { get }

    /// Execute a request and return a single response.
    func execute(input: TransportInput) async throws -> TransportOutput

    /// Execute a request and return a stream of responses.
    ///
    /// Default implementation calls `execute` once and yields the single result.
    func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error>

    /// Whether the transport is currently connected and ready.
    var isConnected: Bool { get async }

    /// Establish the transport connection (e.g., spawn process, open socket).
    func connect() async throws

    /// Gracefully shut down the transport (close connections, kill processes).
    func disconnect() async throws
}

// MARK: - TLS Configuration (v0.3.0)

/// TLS configuration for secure transports.
///
/// Supports certificate pinning and custom trust anchors for transport-level
/// security. Used by HTTP and MCP SSE transports.
public struct TLSConfig: Sendable, Equatable {
    /// Whether to enforce TLS. When true, plaintext connections are rejected.
    public let requireTLS: Bool

    /// Certificate pinning mode.
    public let pinningMode: CertificatePinningMode

    /// SHA-256 hashes of pinned certificate public keys (hex-encoded).
    /// Used when `pinningMode` is `.publicKey`.
    public let pinnedKeyHashes: [String]

    /// Minimum TLS version to accept (default: TLS 1.2).
    public let minimumTLSVersion: TLSVersion

    /// Whether to allow self-signed certificates (for development only).
    public let allowSelfSigned: Bool

    public init(
        requireTLS: Bool = true,
        pinningMode: CertificatePinningMode = .none,
        pinnedKeyHashes: [String] = [],
        minimumTLSVersion: TLSVersion = .tls12,
        allowSelfSigned: Bool = false
    ) {
        self.requireTLS = requireTLS
        self.pinningMode = pinningMode
        self.pinnedKeyHashes = pinnedKeyHashes
        self.minimumTLSVersion = minimumTLSVersion
        self.allowSelfSigned = allowSelfSigned
    }

    /// Development convenience: TLS with self-signed allowed.
    public static let development = TLSConfig(
        requireTLS: false,
        allowSelfSigned: true
    )

    /// Production default: TLS required, minimum TLS 1.2.
    public static let production = TLSConfig(
        requireTLS: true,
        minimumTLSVersion: .tls12
    )
}

/// Certificate pinning mode.
public enum CertificatePinningMode: String, Sendable, Codable, Equatable {
    /// No pinning.
    case none
    /// Pin the certificate's public key (SPKI hash).
    case publicKey
    /// Pin the full certificate hash.
    case certificate
}

/// TLS protocol version.
public enum TLSVersion: String, Sendable, Codable, Equatable, Comparable {
    case tls10 = "1.0"
    case tls11 = "1.1"
    case tls12 = "1.2"
    case tls13 = "1.3"

    private var ordinal: Int {
        switch self {
        case .tls10: return 0
        case .tls11: return 1
        case .tls12: return 2
        case .tls13: return 3
        }
    }

    public static func < (lhs: TLSVersion, rhs: TLSVersion) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// Error thrown when TLS requirements are not met.
public struct TLSError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String {
        "TLS error: \(reason)"
    }
}

// MARK: - Default Implementations

extension Transport {

    /// Default streaming implementation: execute once and yield the result.
    public func executeStream(input: TransportInput) -> AsyncThrowingStream<TransportOutput, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let output = try await self.execute(input: input)
                    continuation.yield(output)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Default: always connected (stateless transports).
    public var isConnected: Bool {
        get async { true }
    }

    /// Default no-op connect.
    public func connect() async throws {}

    /// Default no-op disconnect.
    public func disconnect() async throws {}
}
