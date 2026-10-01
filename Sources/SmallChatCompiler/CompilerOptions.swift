public struct CompilerOptions: Sendable {
    /// Selector pairs at or above this similarity (and below the duplicate
    /// threshold) are reported as collisions; pairs from 0.75 up are
    /// reported as collision-zone warnings.
    public var collisionThreshold: Double
    /// Two distinct tools whose selectors embed at or above this cosine
    /// similarity are duplicates: a compile error unless `allowDuplicates`.
    /// Tools are never merged.
    public var duplicateThreshold: Double
    /// Keep duplicate tools (both are compiled and listed under `duplicates`).
    public var allowDuplicates: Bool
    public var generateSemanticOverloads: Bool
    public var semanticOverloadThreshold: Double

    public init(
        collisionThreshold: Double = 0.89,
        duplicateThreshold: Double = 0.95,
        allowDuplicates: Bool = false,
        generateSemanticOverloads: Bool = false,
        semanticOverloadThreshold: Double = 0.82
    ) {
        self.collisionThreshold = collisionThreshold
        self.duplicateThreshold = duplicateThreshold
        self.allowDuplicates = allowDuplicates
        self.generateSemanticOverloads = generateSemanticOverloads
        self.semanticOverloadThreshold = semanticOverloadThreshold
    }

    /// 0.x name of `duplicateThreshold`. Tools above it used to be merged
    /// silently; they are now a compile error unless `allowDuplicates`.
    @available(*, deprecated, renamed: "init(collisionThreshold:duplicateThreshold:allowDuplicates:generateSemanticOverloads:semanticOverloadThreshold:)")
    public init(
        collisionThreshold: Double = 0.89,
        deduplicationThreshold: Double,
        generateSemanticOverloads: Bool = false,
        semanticOverloadThreshold: Double = 0.82
    ) {
        self.init(
            collisionThreshold: collisionThreshold,
            duplicateThreshold: deduplicationThreshold,
            generateSemanticOverloads: generateSemanticOverloads,
            semanticOverloadThreshold: semanticOverloadThreshold
        )
    }

    /// 0.x name of `duplicateThreshold`.
    @available(*, deprecated, renamed: "duplicateThreshold")
    public var deduplicationThreshold: Double {
        get { duplicateThreshold }
        set { duplicateThreshold = newValue }
    }
}
