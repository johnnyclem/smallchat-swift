import Foundation
import SmallChatCore

// MARK: - VerificationResult

/// The outcome of pre-flight verification (@smallchat/core 1.0
/// `runtime/verification.ts`).
public struct VerificationResult: Sendable, Equatable {
    public let pass: Bool
    /// Whether the supplied arguments name every required parameter
    public let schemaMatch: Bool
    /// Fraction of the intent's keywords found in the tool's name,
    /// description and parameters (0...1)
    public let descriptionOverlap: Double
    /// The LLM verifier's answer, when it was asked
    public let llmConfirmed: Bool?
    /// Why verification failed (nil when it passed)
    public let reason: String?

    public init(pass: Bool, schemaMatch: Bool, descriptionOverlap: Double, llmConfirmed: Bool? = nil, reason: String? = nil) {
        self.pass = pass
        self.schemaMatch = schemaMatch
        self.descriptionOverlap = descriptionOverlap
        self.llmConfirmed = llmConfirmed
        self.reason = reason
    }

    /// Alias of `pass`.
    public var passed: Bool { pass }
}

/// Options for `verify`.
public struct VerificationOptions: Sendable {
    /// Do not ask the LLM, even when one is configured.
    public var skipLLMCheck: Bool
    /// Ask the LLM even when keyword overlap is high (it is otherwise asked
    /// only for borderline overlap). Set when the LLM's answer is what
    /// authorizes a below-HIGH dispatch.
    public var forceLLMCheck: Bool
    /// Skip the required-parameters check (resolving before the call's
    /// arguments are known).
    public var skipSchemaCheck: Bool
    /// Minimum keyword overlap to pass (default 0.15).
    public var minOverlap: Double

    public init(skipLLMCheck: Bool = false, forceLLMCheck: Bool = false, skipSchemaCheck: Bool = false, minOverlap: Double = 0.15) {
        self.skipLLMCheck = skipLLMCheck
        self.forceLLMCheck = forceLLMCheck
        self.skipSchemaCheck = skipSchemaCheck
        self.minOverlap = minOverlap
    }
}

// MARK: - Pre-flight verification

/// Verify that a resolved tool matches the caller's intent -- a lightweight
/// `respondsToSelector:` between resolution and execution. Three
/// progressive strategies:
///   1. Schema: do the arguments name every required parameter?
///   2. Keyword overlap: do the intent's keywords appear in the tool's
///      name, description and parameters (at least `minOverlap`)?
///   3. LLM micro-check: asked when overlap is borderline (< 0.5) or when
///      `forceLLMCheck` is set, unless `skipLLMCheck`.
///
/// A tool whose schema cannot be loaded fails verification.
public func verify(
    _ imp: any ToolIMP,
    intent: String,
    args: [String: any Sendable],
    llm: any LLMClient = NoOpLLMClient(),
    options: VerificationOptions = VerificationOptions()
) async -> VerificationResult {
    let schema: ToolSchema
    if let loaded = imp.schema {
        schema = loaded
    } else if let loaded = try? await imp.loadSchema() {
        schema = loaded
    } else {
        return VerificationResult(pass: false, schemaMatch: false, descriptionOverlap: 0,
                                  reason: "The schema of tool \"\(imp.toolName)\" could not be loaded")
    }

    // Strategy 1: required parameters present
    if !options.skipSchemaCheck {
        let missing = requiredArgumentNames(schema).filter { args[$0] == nil }
        if !missing.isEmpty {
            return VerificationResult(
                pass: false,
                schemaMatch: false,
                descriptionOverlap: 0,
                reason: "Arguments do not match tool \"\(imp.toolName)\" schema — required parameters missing or type mismatch"
            )
        }
    }

    // Strategy 2: keyword overlap
    let overlap = computeKeywordOverlap(intent: intent, schema: schema)
    if overlap < options.minOverlap {
        return VerificationResult(
            pass: false,
            schemaMatch: true,
            descriptionOverlap: overlap,
            reason: "Low keyword overlap (\(Int((overlap * 100).rounded()))%) between intent \"\(intent)\" and tool \"\(imp.toolName)\": \"\(schema.description)\""
        )
    }

    // Strategy 3: LLM micro-check
    if !options.skipLLMCheck, llm.providesVerification, overlap < 0.5 || options.forceLLMCheck {
        let answer = await llm.verifyMatch(intent: intent, toolName: imp.toolName, toolDescription: schema.description)
        let confirmed: Bool
        if case .verified(let confidence) = answer { confirmed = confidence >= 0.5 } else { confirmed = false }
        return VerificationResult(
            pass: confirmed,
            schemaMatch: true,
            descriptionOverlap: overlap,
            llmConfirmed: confirmed,
            reason: confirmed ? nil : "LLM micro-check rejected: tool \"\(imp.toolName)\" does not match intent \"\(intent)\""
        )
    }

    return VerificationResult(pass: true, schemaMatch: true, descriptionOverlap: overlap)
}

/// Names of the required parameters: the schema's `required`, or the
/// required `ArgumentSpec`s.
private func requiredArgumentNames(_ schema: ToolSchema) -> [String] {
    let fromSpecs = schema.arguments.filter(\.required).map(\.name)
    return fromSpecs.isEmpty ? (schema.inputSchema.required ?? []) : fromSpecs
}

// MARK: - Keyword overlap

/// Keyword overlap between an intent and a tool: the fraction of the
/// intent's keywords that appear among the tool's name, description and
/// parameter names and descriptions (0 when either side has none).
public func computeKeywordOverlap(intent: String, schema: ToolSchema) -> Double {
    var text = [schema.name, schema.description]
    text += schema.arguments.map(\.name)
    text += schema.arguments.map(\.description)
    if schema.arguments.isEmpty, let properties = schema.inputSchema.properties {
        for name in properties.keys.sorted() {
            text.append(name)
            text.append(properties[name]?.description ?? "")
        }
    }
    return keywordOverlap(intentTokens: keywordTokens(intent), toolTokens: keywordTokens(text.joined(separator: " ")))
}

/// Keyword overlap between an intent and a tool name plus description (see
/// `computeKeywordOverlap(intent:schema:)`).
public func keywordOverlap(intent: String, toolName: String, toolDescription: String) -> Double {
    keywordOverlap(intentTokens: keywordTokens(intent), toolTokens: keywordTokens("\(toolName) \(toolDescription)"))
}

private func keywordOverlap(intentTokens: Set<String>, toolTokens: Set<String>) -> Double {
    guard !intentTokens.isEmpty, !toolTokens.isEmpty else { return 0 }
    return Double(intentTokens.intersection(toolTokens).count) / Double(intentTokens.count)
}

private let keywordStopwords: Set<String> = [
    "a", "an", "the", "my", "your", "is", "are", "to", "for", "of", "with",
    "and", "or", "in", "on", "at", "by", "do", "this", "that", "it", "i",
    "me", "we", "you", "he", "she", "they", "please", "can", "will",
]

/// Lower-case ASCII keywords: anything but `[a-z0-9]`, whitespace, `_` and
/// `-` becomes a space, then the text splits on whitespace, `_` and `-`
/// (so `delete_records` gives "delete" and "records"); one-letter words and
/// stopwords are dropped.
func keywordTokens(_ text: String) -> Set<String> {
    var tokens = Set<String>()
    var current = ""
    func flush() {
        if current.count > 1, !keywordStopwords.contains(current) { tokens.insert(current) }
        current = ""
    }
    for scalar in text.lowercased().unicodeScalars {
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39:
            current.unicodeScalars.append(scalar)
        default:
            flush()
        }
    }
    flush()
    return tokens
}
