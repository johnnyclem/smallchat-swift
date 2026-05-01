import Testing
@testable import SmallChatShorthand

@Suite("Shorthand")
struct ShorthandTests {

    @Test("tokens drops short words and stop-words")
    func tokensFilters() {
        let toks = Shorthand.tokens(in: "the quick brown fox jumps")
        #expect(toks == ["quick", "brown", "fox", "jumps"])
    }

    @Test("tokens preserves stop-words when filtering disabled")
    func tokensKeepsStopWordsWhenAsked() {
        let toks = Shorthand.tokens(in: "the quick brown fox", removeStopWords: false)
        #expect(toks.contains("the"))
    }

    @Test("sentences split on . ! ? and newline")
    func sentencesSplit() {
        let s = Shorthand.sentences(in: "First. Second! Third?\nFourth")
        #expect(s == ["First", "Second", "Third", "Fourth"])
    }

    @Test("Jaccard returns 0 for disjoint, 1 for identical")
    func jaccardBounds() {
        #expect(Shorthand.jaccard(["a", "b"], ["c", "d"]) == 0)
        #expect(Shorthand.jaccard(["a", "b"], ["a", "b"]) == 1)
    }

    @Test("Cosine of orthogonal vectors is 0; of identical vectors is 1")
    func cosineBounds() {
        let zero = Shorthand.cosine([1, 0], [0, 1])
        #expect(zero == 0)
        let one = Shorthand.cosine([1, 1], [1, 1])
        #expect(abs(one - 1.0) < 1e-9)
    }

    @Test("Content hash is deterministic and content-sensitive")
    func contentHashStable() {
        let a = Shorthand.contentHash("hello world")
        let b = Shorthand.contentHash("hello world")
        let c = Shorthand.contentHash("hello world!")
        #expect(a == b)
        #expect(a != c)
    }
}
