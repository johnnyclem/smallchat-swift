import Foundation

// MARK: - SmallChatCRDT
//
// CRDT-based shared memory for multi-agent coordination, ported from
// TS PR #56. Provides:
//
//   - VectorClock      -- per-replica logical timestamps for happens-before
//   - LWWMap           -- last-write-wins map keyed by `String`
//   - ORSet            -- observed-remove set with tombstones
//   - GCounter         -- grow-only counter
//
// Each type exposes a deterministic `merge(other:)` such that:
//   commutative:  merge(a, b) == merge(b, a)
//   idempotent:   merge(a, a) == a
//   associative:  merge(merge(a, b), c) == merge(a, merge(b, c))

// MARK: - Replica id

public typealias ReplicaID = String

// MARK: - VectorClock

/// Map of replica id -> sequence number.
public struct VectorClock: Sendable, Codable, Equatable {
    public private(set) var counters: [ReplicaID: Int]

    public init(counters: [ReplicaID: Int] = [:]) {
        self.counters = counters
    }

    /// Increment our own counter and return the new clock.
    public func ticked(by replica: ReplicaID) -> VectorClock {
        var c = counters
        c[replica, default: 0] += 1
        return VectorClock(counters: c)
    }

    /// Pointwise maximum.
    public func merged(with other: VectorClock) -> VectorClock {
        var c = counters
        for (id, v) in other.counters {
            c[id] = max(c[id] ?? 0, v)
        }
        return VectorClock(counters: c)
    }

    /// Strict happens-before: every entry <= other's, with at least one <.
    public func happensBefore(_ other: VectorClock) -> Bool {
        var sawStrict = false
        let allKeys = Set(counters.keys).union(other.counters.keys)
        for k in allKeys {
            let a = counters[k] ?? 0
            let b = other.counters[k] ?? 0
            if a > b { return false }
            if a < b { sawStrict = true }
        }
        return sawStrict
    }

    /// Concurrent: neither happens-before the other and they aren't equal.
    public func concurrent(with other: VectorClock) -> Bool {
        !self.happensBefore(other) && !other.happensBefore(self) && self != other
    }
}

// MARK: - LWWMap

/// Last-Write-Wins map. Conflicts are resolved by:
///   1. Higher Lamport timestamp wins.
///   2. On equal timestamps, lexicographically larger replica id wins.
public struct LWWMap<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {

    public struct Entry: Sendable, Codable, Equatable {
        public let value: Value
        public let timestamp: Int
        public let replica: ReplicaID
        public let tombstoned: Bool

        public init(value: Value, timestamp: Int, replica: ReplicaID, tombstoned: Bool = false) {
            self.value = value
            self.timestamp = timestamp
            self.replica = replica
            self.tombstoned = tombstoned
        }

        /// Wins between two entries that map to the same key.
        func wins(over other: Entry) -> Bool {
            if timestamp != other.timestamp { return timestamp > other.timestamp }
            return replica > other.replica
        }
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public func value(for key: String) -> Value? {
        guard let entry = entries[key], !entry.tombstoned else { return nil }
        return entry.value
    }

    public func set(_ key: String, to value: Value, timestamp: Int, replica: ReplicaID) -> LWWMap {
        let proposed = Entry(value: value, timestamp: timestamp, replica: replica)
        var copy = entries
        if let existing = copy[key] {
            if proposed.wins(over: existing) { copy[key] = proposed }
        } else {
            copy[key] = proposed
        }
        return LWWMap(entries: copy)
    }

    public func remove(_ key: String, value: Value, timestamp: Int, replica: ReplicaID) -> LWWMap {
        let tomb = Entry(value: value, timestamp: timestamp, replica: replica, tombstoned: true)
        var copy = entries
        if let existing = copy[key] {
            if tomb.wins(over: existing) { copy[key] = tomb }
        } else {
            copy[key] = tomb
        }
        return LWWMap(entries: copy)
    }

    public func merged(with other: LWWMap) -> LWWMap {
        var copy = entries
        for (k, e) in other.entries {
            if let existing = copy[k] {
                if e.wins(over: existing) { copy[k] = e }
            } else {
                copy[k] = e
            }
        }
        return LWWMap(entries: copy)
    }
}

// MARK: - ORSet

/// Observed-Remove Set. An element is in the set iff at least one of its
/// adds is not shadowed by a remove tagged with the same unique id.
public struct ORSet<Element: Sendable & Codable & Hashable>: Sendable, Codable, Equatable {

    public private(set) var adds: [Element: Set<String>]
    public private(set) var removes: [Element: Set<String>]

    public init(
        adds: [Element: Set<String>] = [:],
        removes: [Element: Set<String>] = [:]
    ) {
        self.adds = adds
        self.removes = removes
    }

    public var members: Set<Element> {
        var out: Set<Element> = []
        for (e, addTags) in adds {
            let rms = removes[e] ?? []
            if !addTags.subtracting(rms).isEmpty { out.insert(e) }
        }
        return out
    }

    public func contains(_ element: Element) -> Bool {
        members.contains(element)
    }

    public func adding(_ element: Element, tag: String) -> ORSet {
        var newAdds = adds
        newAdds[element, default: []].insert(tag)
        return ORSet(adds: newAdds, removes: removes)
    }

    /// Remove an element by tombstoning every currently-observed add tag.
    public func removing(_ element: Element) -> ORSet {
        var newRemoves = removes
        if let observed = adds[element] {
            newRemoves[element, default: []].formUnion(observed)
        }
        return ORSet(adds: adds, removes: newRemoves)
    }

    public func merged(with other: ORSet) -> ORSet {
        var newAdds = adds
        for (e, tags) in other.adds {
            newAdds[e, default: []].formUnion(tags)
        }
        var newRemoves = removes
        for (e, tags) in other.removes {
            newRemoves[e, default: []].formUnion(tags)
        }
        return ORSet(adds: newAdds, removes: newRemoves)
    }
}

// MARK: - GCounter

/// Grow-only counter.
public struct GCounter: Sendable, Codable, Equatable {
    public private(set) var counts: [ReplicaID: Int]

    public init(counts: [ReplicaID: Int] = [:]) {
        self.counts = counts
    }

    public var value: Int { counts.values.reduce(0, +) }

    public func incremented(by replica: ReplicaID, amount: Int = 1) -> GCounter {
        precondition(amount >= 0, "GCounter cannot decrement")
        var c = counts
        c[replica, default: 0] += amount
        return GCounter(counts: c)
    }

    public func merged(with other: GCounter) -> GCounter {
        var c = counts
        for (id, v) in other.counts {
            c[id] = max(c[id] ?? 0, v)
        }
        return GCounter(counts: c)
    }
}
