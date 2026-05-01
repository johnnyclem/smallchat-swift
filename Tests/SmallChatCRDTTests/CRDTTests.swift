import Testing
@testable import SmallChatCRDT

@Suite("CRDT primitives")
struct CRDTTests {

    // MARK: - VectorClock

    @Test("VectorClock detects happens-before")
    func clockHappensBefore() {
        let c1 = VectorClock().ticked(by: "a")
        let c2 = c1.ticked(by: "a").ticked(by: "b")
        #expect(c1.happensBefore(c2))
        #expect(!c2.happensBefore(c1))
    }

    @Test("Concurrent edits are detected")
    func clockConcurrent() {
        let c1 = VectorClock().ticked(by: "a")
        let c2 = VectorClock().ticked(by: "b")
        #expect(c1.concurrent(with: c2))
    }

    @Test("VectorClock merge is pointwise max and idempotent")
    func clockMerge() {
        let a = VectorClock(counters: ["a": 3, "b": 1])
        let b = VectorClock(counters: ["a": 2, "b": 4, "c": 1])
        let merged = a.merged(with: b)
        #expect(merged.counters["a"] == 3)
        #expect(merged.counters["b"] == 4)
        #expect(merged.counters["c"] == 1)
        #expect(merged.merged(with: merged) == merged)
    }

    // MARK: - LWWMap

    @Test("LWWMap: higher timestamp wins")
    func lwwTimestampWins() {
        var m = LWWMap<String>()
        m = m.set("k", to: "v1", timestamp: 1, replica: "a")
        m = m.set("k", to: "v2", timestamp: 5, replica: "b")
        #expect(m.value(for: "k") == "v2")
        // Equal timestamps: higher replica id wins.
        m = m.set("k", to: "v3", timestamp: 5, replica: "c")
        #expect(m.value(for: "k") == "v3")
    }

    @Test("LWWMap merge is commutative")
    func lwwMergeCommutative() {
        let a = LWWMap<String>().set("k", to: "x", timestamp: 1, replica: "a")
        let b = LWWMap<String>().set("k", to: "y", timestamp: 2, replica: "b")
        let m1 = a.merged(with: b)
        let m2 = b.merged(with: a)
        #expect(m1 == m2)
        #expect(m1.value(for: "k") == "y")
    }

    @Test("LWWMap remove tombstones with timestamp ordering")
    func lwwRemove() {
        var m = LWWMap<String>()
        m = m.set("k", to: "v1", timestamp: 1, replica: "a")
        m = m.remove("k", value: "v1", timestamp: 3, replica: "a")
        #expect(m.value(for: "k") == nil)
        // A later set wins over the tombstone.
        m = m.set("k", to: "v2", timestamp: 4, replica: "a")
        #expect(m.value(for: "k") == "v2")
    }

    // MARK: - ORSet

    @Test("ORSet: add then remove leaves no member; concurrent add+remove keeps the add")
    func orSetSemantics() {
        let s1 = ORSet<String>()
            .adding("x", tag: "t1")
            .removing("x")
        #expect(!s1.contains("x"))

        // Concurrent: replica 1 removes existing tag, replica 2 adds with a fresh tag.
        let r1 = ORSet<String>().adding("x", tag: "t1").removing("x")
        let r2 = ORSet<String>().adding("x", tag: "t2")
        let merged = r1.merged(with: r2)
        #expect(merged.contains("x"))
    }

    @Test("ORSet merge is commutative and idempotent")
    func orSetMerge() {
        let a = ORSet<String>().adding("x", tag: "t1").adding("y", tag: "t2")
        let b = ORSet<String>().adding("y", tag: "t3").adding("z", tag: "t4")
        let m1 = a.merged(with: b)
        let m2 = b.merged(with: a)
        #expect(m1 == m2)
        #expect(m1.merged(with: m1) == m1)
        #expect(m1.members == ["x", "y", "z"])
    }

    // MARK: - GCounter

    @Test("GCounter: monotonic increment, merge takes pointwise max")
    func gcounter() {
        let a = GCounter().incremented(by: "a", amount: 3)
        let b = GCounter().incremented(by: "b", amount: 5)
        let merged = a.merged(with: b)
        #expect(merged.value == 8)
        #expect(merged.merged(with: merged).value == 8)
    }
}
