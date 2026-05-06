/// ComponentSelector -- a selector for a UI component within an App.
///
/// Parallel to `ToolSelector` but for the App/UI layer.
/// Equality and hashing are based solely on `canonical` so that
/// semantically equivalent components resolve to the same cache key.
public struct ComponentSelector: Sendable, Equatable, Hashable, Codable {
    public let canonical: String
    public let vector: [Float]
    public let intentText: String

    public init(canonical: String, vector: [Float], intentText: String) {
        self.canonical = canonical
        self.vector = vector
        self.intentText = intentText
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonical == rhs.canonical
    }
}
