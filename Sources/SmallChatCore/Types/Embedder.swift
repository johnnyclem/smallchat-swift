public protocol Embedder: Sendable {
    var dimensions: Int { get }
    /// What produced this embedder's vectors (artifact format 1.0). Vectors
    /// from embedders with different fingerprints are not comparable, so an
    /// artifact is only usable with an embedder whose fingerprint equals the
    /// one it records. nil: the embedder declares none, and cannot load or
    /// compile 1.0 artifacts.
    var fingerprint: EmbedderFingerprint? { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    public var fingerprint: EmbedderFingerprint? { nil }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (i, text) in texts.enumerated() {
                group.addTask { (i, try await self.embed(text)) }
            }
            var results = Array(repeating: [Float](), count: texts.count)
            for try await (i, vec) in group {
                results[i] = vec
            }
            return results
        }
    }
}

// MARK: - EmbedderFingerprint

/// The identity of an embedding function (artifact format 1.0 `embedder`).
/// Two fingerprints describe the same embedder only when all seven fields
/// are equal.
public struct EmbedderFingerprint: Sendable, Codable, Equatable, Hashable {
    /// `onnx`, `hash` or `custom`.
    public var kind: String
    public var model: String
    /// SHA-256 of the model file; nil only for the hash embedder.
    public var modelSha256: String?
    public var dims: Int
    public var maxLength: Int?
    /// `mean`, `cls` or `none`.
    public var pooling: String
    public var normalize: Bool

    public init(
        kind: String,
        model: String,
        modelSha256: String?,
        dims: Int,
        maxLength: Int?,
        pooling: String,
        normalize: Bool
    ) {
        self.kind = kind
        self.model = model
        self.modelSha256 = modelSha256
        self.dims = dims
        self.maxLength = maxLength
        self.pooling = pooling
        self.normalize = normalize
    }

    /// Algorithm id the hash embedder records (`LocalEmbedder`, TypeScript `HashEmbedder`).
    public static let hashModel = "smallchat-hash-v1"

    /// The fingerprint of the hash embedder at `dims` dimensions.
    public static func hash(dims: Int) -> EmbedderFingerprint {
        EmbedderFingerprint(kind: "hash", model: hashModel, modelSha256: nil, dims: dims, maxLength: nil, pooling: "none", normalize: true)
    }

    /// The fingerprint as a JSON object, with explicit nulls (as recorded in artifacts and proofs).
    public var jsonValue: [String: AnyCodableValue] {
        [
            "kind": .string(kind),
            "model": .string(model),
            "modelSha256": modelSha256.map { .string($0) } ?? .null,
            "dims": .int(dims),
            "maxLength": maxLength.map { .int($0) } ?? .null,
            "pooling": .string(pooling),
            "normalize": .bool(normalize),
        ]
    }

    /// One-line human description, e.g. for errors.
    public var summary: String {
        var details: [String] = []
        if let modelSha256 { details.append("sha256 \(modelSha256.prefix(12))…") }
        details.append("\(dims) dims")
        if let maxLength { details.append("maxLength \(maxLength)") }
        if pooling != "none" { details.append("\(pooling) pooling") }
        details.append(normalize ? "normalized" : "unnormalized")
        return "\(kind) \(model) (\(details.joined(separator: ", ")))"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }
}
