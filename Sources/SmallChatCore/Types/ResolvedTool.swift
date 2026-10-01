import Foundation

public struct ResolvedTool: Sendable {
    public let selector: ToolSelector
    public let imp: any ToolIMP
    public var confidence: Double
    public let resolvedAt: Date
    public var hitCount: Int
    public var providerVersion: String?
    public var modelVersion: String?
    public var schemaFingerprint: String?
    /// The registry generation of the dispatch context that stored the
    /// entry (`DispatchContext.registryGeneration`). Dispatch uses only
    /// entries stamped with its current generation.
    public var registryGeneration: UInt64?

    public init(
        selector: ToolSelector,
        imp: any ToolIMP,
        confidence: Double,
        resolvedAt: Date = Date(),
        hitCount: Int = 0,
        providerVersion: String? = nil,
        modelVersion: String? = nil,
        schemaFingerprint: String? = nil,
        registryGeneration: UInt64? = nil
    ) {
        self.selector = selector
        self.imp = imp
        self.confidence = confidence
        self.resolvedAt = resolvedAt
        self.hitCount = hitCount
        self.providerVersion = providerVersion
        self.modelVersion = modelVersion
        self.schemaFingerprint = schemaFingerprint
        self.registryGeneration = registryGeneration
    }
}
