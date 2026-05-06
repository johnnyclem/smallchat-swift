import Foundation

// MARK: - RTK Metadata

/// Compression metadata attached by `RtkTransport` to every response it processes.
///
/// Mirrors the TypeScript `TransportMetadata.rtk` shape.
public struct RtkMetadata: Sendable, Equatable {
    /// Whether RTK actually compressed the content.
    public let enabled: Bool
    /// Original byte count before compression.
    public let inputBytes: Int
    /// Byte count after compression (equals `inputBytes` when `enabled` is false).
    public let outputBytes: Int
    /// Percentage of bytes saved (0–100). Zero when `enabled` is false.
    public let savedPct: Double
    /// Which RTK mode ran.
    public let mode: RtkMode

    public init(enabled: Bool, inputBytes: Int, outputBytes: Int, savedPct: Double, mode: RtkMode) {
        self.enabled = enabled
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.savedPct = savedPct
        self.mode = mode
    }
}

/// Which RTK processing mode produced the metadata.
public enum RtkMode: String, Sendable, Codable, Equatable {
    case none
    case filter
    case prefix
}

// MARK: - TransportOutput

/// Output from a transport operation.
///
/// Mirrors the TypeScript `TransportOutput` and `TransportMetadata` interfaces.
public struct TransportOutput: Sendable {

    /// HTTP status code (0 for non-HTTP transports).
    public var statusCode: Int

    /// Response headers.
    public var headers: [String: String]

    /// Response body as raw data.
    public var body: Data?

    /// Arbitrary metadata about the response (timing, circuit state, etc.).
    public var metadata: [String: String]

    /// RTK compression metadata, present when `RtkTransport` processed this response.
    public var rtkMetadata: RtkMetadata?

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data? = nil,
        metadata: [String: String] = [:],
        rtkMetadata: RtkMetadata? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.metadata = metadata
        self.rtkMetadata = rtkMetadata
    }

    // MARK: - Convenience

    /// Whether this response represents an error (status >= 400 or metadata flag).
    public var isError: Bool {
        statusCode >= 400 || metadata["isError"] == "true"
    }

    /// Decode the body as JSON into the given `Decodable` type.
    public func decoded<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let body else {
            throw TransportError.invalidResponse(message: "No body data to decode")
        }
        return try decoder.decode(type, from: body)
    }

    /// Decode the body as a UTF-8 string.
    public var bodyString: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }
}
