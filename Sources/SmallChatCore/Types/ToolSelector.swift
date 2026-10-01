public struct ToolSelector: Sendable, Equatable, Hashable {
    public let vector: [Float]
    public let canonical: String
    public let parts: [String]
    public let arity: Int
    /// For a runtime intent: its identity key (`intentKey`), which the
    /// resolution cache keys on. nil for a compiled tool or alias selector.
    public let key: String?

    public init(
        vector: [Float],
        canonical: String,
        parts: [String],
        arity: Int,
        key: String? = nil
    ) {
        self.vector = vector
        self.canonical = canonical
        self.parts = parts
        self.arity = arity
        self.key = key
    }

    /// The selector of a runtime intent: its own embedding, its display
    /// canonical (`canonicalize`) and its identity key (`intentKey`). Never
    /// added to a selector table or vector index.
    public static func intent(_ intent: String, vector: [Float]) -> ToolSelector {
        let canonical = canonicalize(intent)
        let parts = canonical.split(separator: ":").map(String.init)
        return ToolSelector(
            vector: vector,
            canonical: canonical,
            parts: parts,
            arity: max(0, parts.count - 1),
            key: intentKey(intent)
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonical == rhs.canonical
    }
}
