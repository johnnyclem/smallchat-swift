import SmallChatCore
import Foundation

/// Hash-based embedding for development/testing.
///
/// Byte-for-byte compatible with the TypeScript `LocalEmbedder`
/// (`src/embedding/local-embedder.ts`) so that artifacts compiled by either
/// implementation resolve identically. The algorithm is deliberately *not*
/// semantically meaningful — it is a deterministic placeholder that lets the
/// dispatch pipeline run end-to-end. For semantic vectors, conform an
/// `Embedder` backed by a real model (smallchat-swift ships none).
///
/// ## ABI notes
/// The reference implementation hashes UTF-16 code units (`charCodeAt`) and folds
/// with `hash = (hash * 0x01000193) | 0`, i.e. a **double-precision** multiply
/// truncated to a signed 32-bit integer. Because `|hash| * 16777619` can exceed
/// 2^53, the JS multiply rounds in a specific way; `Embedding.jsImul` reproduces
/// that rounding exactly so the resulting vectors are identical.
public struct LocalEmbedder: Embedder, Sendable {
    public let dimensions: Int

    public init(dimensions: Int = 384) {
        self.dimensions = dimensions
    }

    /// `hash` / `smallchat-hash-v1` at this embedder's dimensions: the same
    /// fingerprint as @smallchat/core's `HashEmbedder`, whose vectors this
    /// embedder reproduces.
    public var fingerprint: EmbedderFingerprint? { .hash(dims: dimensions) }

    public func embed(_ text: String) async throws -> [Float] {
        LocalEmbedder.hashEmbed(text, dimensions: dimensions)
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        texts.map { LocalEmbedder.hashEmbed($0, dimensions: dimensions) }
    }

    /// Deterministic hash embedding. Public + static so parity tests can call it directly.
    public static func hashEmbed(_ text: String, dimensions: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)

        for word in tokenize(text) {
            let h = fnv1a(word)
            vector[index(h, dimensions)] += 1.0

            // Character trigrams for sub-word similarity (word is ASCII here).
            let scalars = Array(word.unicodeScalars)
            if scalars.count >= 3 {
                var i = 0
                while i <= scalars.count - 3 {
                    let trigram = String(String.UnicodeScalarView(scalars[i..<(i + 3)]))
                    vector[index(fnv1a(trigram), dimensions)] += 0.5
                    i += 1
                }
            }
        }

        // L2-normalize as the reference does: the norm in double precision,
        // each float32 component divided by it, so vectors match bit for bit.
        var norm = 0.0
        for v in vector { norm += Double(v) * Double(v) }
        norm = norm.squareRoot()
        if norm > 0 {
            for i in 0..<vector.count { vector[i] = Float(Double(vector[i]) / norm) }
        }
        return vector
    }

    // MARK: - Tokenization (matches `text.toLowerCase().replace(/[^a-z0-9\s]/g,'').split(/\s+/).filter(Boolean)`)

    /// Lowercase, drop every scalar that is not ASCII `[a-z0-9]` or whitespace,
    /// then split on whitespace runs. Whitespace follows the JS `\s` class.
    static func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                // a-z, 0-9
                current.unicodeScalars.append(scalar)
            } else if isJSWhitespace(scalar) {
                if !current.isEmpty { words.append(current); current = "" }
            }
            // anything else is stripped (acts as nothing, not a separator) — matches
            // `replace(/[^a-z0-9\s]/g,'')` which deletes the char without splitting.
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// JavaScript regex `\s` whitespace class.
    private static func isJSWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,        // \t \n \v \f \r space
             0xA0, 0x1680,
             0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
             0xFEFF:                                     // ZWNBSP — JS \s includes it
            return true
        default:
            return false
        }
    }

    // MARK: - FNV-1a over UTF-16 code units, matching the JS reference exactly

    /// `Math.abs(h) % dimensions`, computed in 64-bit to survive `Int32.min`
    /// (whose JS `Math.abs` is `2147483648`, not an overflow).
    private static func index(_ h: Int32, _ dimensions: Int) -> Int {
        let absH = h == Int32.min ? Int64(2147483648) : Int64(abs(Int(h)))
        return Int(absH % Int64(dimensions))
    }

    static func fnv1a(_ str: String) -> Int32 {
        var hash: Int32 = Int32(bitPattern: 0x811c_9dc5)
        for unit in str.utf16 {
            hash ^= Int32(unit)                 // charCodeAt(i): UTF-16 code unit
            hash = jsImul(hash, 0x0100_0193)    // (hash * prime) | 0  — double-precision then ToInt32
        }
        return hash
    }

    /// Reproduces JavaScript `(a * b) | 0`: multiply as IEEE-754 doubles, then ToInt32.
    /// This intentionally mirrors the precision loss of the reference (it does NOT
    /// compute the exact 32-bit modular product like `Math.imul`).
    static func jsImul(_ a: Int32, _ b: Int32) -> Int32 {
        let product = Double(a) * Double(b)
        return toInt32(product)
    }

    /// ECMAScript ToInt32 on a finite double.
    static func toInt32(_ d: Double) -> Int32 {
        guard d.isFinite else { return 0 }
        let twoTo32 = 4_294_967_296.0
        var n = d.rounded(.towardZero)              // ToInteger (truncate toward zero)
        n = n.truncatingRemainder(dividingBy: twoTo32)  // n modulo 2^32, in (-2^32, 2^32)
        if n < 0 { n += twoTo32 }                   // map to [0, 2^32)
        if n >= 2_147_483_648.0 { n -= twoTo32 }    // map to signed [-2^31, 2^31)
        return Int32(n)
    }
}

// MARK: - Built-in embedders by fingerprint

/// The built-in embedder an artifact fingerprint names, ready to use with
/// that artifact. smallchat-swift ships only the hash embedder
/// (`LocalEmbedder`); an artifact compiled with ONNX (the @smallchat/core
/// default) or a custom embedder needs one supplied by the caller that
/// declares the same fingerprint. Throws `EmbedderMismatchError` otherwise.
public func builtinEmbedder(for fingerprint: EmbedderFingerprint) throws -> any Embedder {
    let hash = EmbedderFingerprint.hash(dims: fingerprint.dims)
    if fingerprint == hash, fingerprint.dims > 0 {
        return LocalEmbedder(dimensions: fingerprint.dims)
    }
    throw EmbedderMismatchError(
        "The artifact was compiled with \(fingerprint.summary), and smallchat-swift has no built-in embedder "
        + "for it (only \(EmbedderFingerprint.hashModel)). Pass an embedder that declares exactly this fingerprint, "
        + "or recompile the toolkit with the hash embedder (`smallchat compile`)."
    )
}
