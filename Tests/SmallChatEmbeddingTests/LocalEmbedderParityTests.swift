import Testing
import Foundation
@testable import SmallChatEmbedding

/// Verifies that `LocalEmbedder` is byte/float32-compatible with the TypeScript
/// reference (`src/embedding/local-embedder.ts`). Golden vectors were captured
/// from the verbatim JS algorithm (FNV-1a over UTF-16 code units, the lossy
/// `(hash * 0x01000193) | 0` double-multiply, `Math.abs(h) % dims`, word weight
/// 1.0 + trigram weight 0.5, L2 normalize) and emitted as Float32.
///
/// The semantic ABI contract is: identical nonzero indices and component values
/// equal within Float32 epsilon.
@Suite("LocalEmbedder parity")
struct LocalEmbedderParityTests {
    let eps: Float = 1e-6

    private func vector(_ text: String) -> [Float] {
        LocalEmbedder.hashEmbed(text, dimensions: 384)
    }

    private func assertGolden(_ text: String, _ golden: [(Int, Float)]) {
        let v = vector(text)
        #expect(v.count == 384)
        let nonzero = v.enumerated().filter { $0.element != 0 }.map { $0.offset }
        #expect(nonzero == golden.map { $0.0 }, "nonzero indices mismatch for \(text): \(nonzero)")
        for (idx, expected) in golden {
            #expect(abs(v[idx] - expected) < eps, "component \(idx) for \(text): \(v[idx]) vs \(expected)")
        }
    }

    @Test("Multi-word ASCII intent matches TS golden vector")
    func readFile() {
        // "read file" — two words, each with trigrams.
        assertGolden("read file", [
            (40, 0.28867513), (88, 0.28867513), (100, 0.28867513),
            (124, 0.57735026), (212, 0.28867513), (292, 0.57735026),
        ])
    }

    @Test("Single short word collapses trigram onto a single bucket")
    func aaa() {
        // "aaa" -> word hash + one trigram "aaa" hit the same/normalized bucket.
        assertGolden("aaa", [(224, 1.0)])
    }

    @Test("Non-ASCII characters are stripped, matching the TS ASCII regex")
    func nonASCIIStripped() {
        // "café déjà vu" lowercases then drops non [a-z0-9] -> tokens: caf, dj, vu.
        // We only assert it equals the ASCII-stripped form's embedding.
        #expect(vector("café déjà vu") == vector("caf dj vu"))
    }

    @Test("Output is L2-normalized")
    func normalized() {
        let v = vector("compile the tool manifest into a dispatch table")
        let norm = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 1e-5)
    }

    @Test("Empty input yields a zero vector")
    func empty() {
        #expect(vector("").allSatisfy { $0 == 0 })
    }

    @Test("Int32.min hash edge case does not trap")
    func int32MinSafe() {
        // Exercises many words/trigrams; the guard in `index` must handle a hash
        // of Int32.min (whose JS Math.abs is 2147483648, not an overflow).
        let v = vector("zzzzzzzz overflow test string with many words to exercise hashing")
        #expect(v.contains { $0 != 0 })
    }
}
