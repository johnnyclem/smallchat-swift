// MARK: - ToolRefinement

/// Structured "tool_refinement_needed" payload returned for NONE-tier
/// dispatches.
///
/// Mirrors the MCP result type added in TS PR #54. The payload tells the
/// caller why no tool was confidently selected and what to ask next.
public struct ToolRefinement: Sendable, Codable, Equatable {
    /// The original intent the caller submitted.
    public let originalIntent: String
    /// Human-readable explanation of why no tool dispatched.
    public let reason: String
    /// Specific clarifying questions the caller could ask the user.
    public let clarifyingQuestions: [String]
    /// Top candidates that almost matched, with their confidence.
    public let nearMatches: [NearMatch]
    /// Replayable proof of how resolution arrived at this refinement.
    public let proof: ResolutionProof

    public struct NearMatch: Sendable, Codable, Equatable {
        public let toolName: String
        public let providerId: String
        public let canonicalSelector: String
        public let confidence: Double

        public init(
            toolName: String,
            providerId: String,
            canonicalSelector: String,
            confidence: Double
        ) {
            self.toolName = toolName
            self.providerId = providerId
            self.canonicalSelector = canonicalSelector
            self.confidence = confidence
        }
    }

    public init(
        originalIntent: String,
        reason: String,
        clarifyingQuestions: [String] = [],
        nearMatches: [NearMatch] = [],
        proof: ResolutionProof = ResolutionProof()
    ) {
        self.originalIntent = originalIntent
        self.reason = reason
        self.clarifyingQuestions = clarifyingQuestions
        self.nearMatches = nearMatches
        self.proof = proof
    }

    /// MCP wire constant: the result type discriminator.
    public static let mcpResultType = "tool_refinement_needed"
}
