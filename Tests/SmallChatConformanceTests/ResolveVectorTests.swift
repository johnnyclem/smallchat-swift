import Foundation
import Testing
import SmallChatCore
import SmallChatRuntime
import SmallChatEmbedding

/// spec/resolve/vectors.json (smallchat.resolve.v1): given each tool's
/// similarity to the intent, its annotations, intent pins and policy
/// options, `resolve()` reaches the expected outcome, decision, tier,
/// chosen tool, candidate order and exclusions -- as @smallchat/core does.
@Suite("Conformance: resolve outcomes (spec/resolve)")
struct ResolveVectorTests {
    static let spec = try! SpecFixtures.json("resolve/vectors.json")

    @Test("the vectors are smallchat.resolve.v1")
    func version() {
        #expect(Self.spec["version"]?.stringValue == "smallchat.resolve.v1")
    }

    @Test("every case", arguments: Self.spec["cases"]!.arrayValue)
    func resolveCase(_ c: AnyCodableValue) async throws {
        let name = c["name"]?.stringValue ?? "?"
        let intent = try #require(c["intent"]?.stringValue)
        let runtime = try await Self.runtime(for: c, intent: intent)
        let resolution = try await runtime.resolve(intent)

        let expect = try #require(c["expect"])
        #expect(resolution.outcome.rawValue == expect["outcome"]?.stringValue, "\(name): outcome")
        #expect(resolution.proof.decision.rawValue == expect["decision"]?.stringValue, "\(name): decision")
        #expect(resolution.tier.rawValue == expect["tier"]?.stringValue, "\(name): tier")
        #expect(resolution.chosen == expect["chosen"]?.stringValue, "\(name): chosen")
        #expect(resolution.candidates.map(\.toolId) == expect["candidates"]!.arrayValue.compactMap(\.stringValue), "\(name): candidates")
        if let excluded = expect["excluded"] {
            let actual = resolution.proof.candidates.compactMap { candidate -> [String]? in
                candidate.excluded.map { [candidate.toolId, $0] }
            }
            let expected = excluded.arrayValue.map { [$0["toolId"]?.stringValue ?? "", $0["reason"]?.stringValue ?? ""] }
            #expect(actual == expected, "\(name): excluded")
        }
        // resolve() never executes anything.
        #expect(resolution.proof.ran == nil, "\(name): ran")
    }

    // MARK: - Building a case (spec/resolve/README.md, "Running a case")

    /// Embeds the case's intent as e0 and anything else as the last axis.
    private struct AxisEmbedder: Embedder {
        let intent: String
        let dimensions: Int
        func embed(_ text: String) async throws -> [Float] {
            var v = [Float](repeating: 0, count: dimensions)
            v[text == intent ? 0 : dimensions - 1] = 1
            return v
        }
    }

    /// An LLM verifier that approves exactly the listed tool names.
    private struct ApprovingLLM: LLMClient {
        let approve: [String]
        func verifyMatch(intent: String, toolName: String, toolDescription: String) async -> LLMVerificationResult {
            approve.contains(toolName) ? .verified(confidence: 1) : .rejected(reason: "not approved")
        }
        func decompose(intent: String) async -> LLMDecompositionResult { .unavailable }
        func clarifyingQuestions(intent: String, nearMatches: [String]) async -> [String] { [] }
    }

    private final class CaseIMP: ToolIMP, @unchecked Sendable {
        let providerId: String
        let toolName: String
        let transportType: TransportType = .local
        let schema: ToolSchema?
        let annotations: ToolAnnotations?
        init(providerId: String, toolName: String, intent: String, annotations: ToolAnnotations?) {
            self.providerId = providerId
            self.toolName = toolName
            // The description is the intent itself, so keyword verification passes.
            self.schema = ToolSchema(name: toolName, description: intent, inputSchema: JSONSchemaType(type: "object"))
            self.annotations = annotations
        }
        func loadSchema() async throws -> ToolSchema { schema! }
        func execute(args: [String: any Sendable]) async throws -> ToolResult {
            Issue.record("resolve() executed \(providerId)/\(toolName)")
            return ToolResult(content: nil)
        }
    }

    static func selectorOf(_ toolId: String) throws -> String {
        let (providerId, toolName) = try parseToolId(toolId)
        return "\(providerId).\(toolName)"
    }

    static func runtime(for c: AnyCodableValue, intent: String) async throws -> ToolRuntime {
        let tools = c["tools"]!.arrayValue
        let dims = tools.count + 2
        let options = c["options"]

        var config = DispatchConfig()
        if let require = options?["requireLLMForSubHighDispatch"]?.boolValue { config.requireLLMForSubHighDispatch = require }
        if let unannotated = options?["treatUnannotatedAsDestructive"]?.boolValue { config.treatUnannotatedAsDestructive = unannotated }
        let llm: any LLMClient = options?["llm"].map { ApprovingLLM(approve: $0["approve"]!.arrayValue.compactMap(\.stringValue)) } ?? NoOpLLMClient()

        var pins: [IntentPin] = []
        for pin in c["pins"]?.arrayValue ?? [] {
            let phrases = pin["phrases"]?.arrayValue.compactMap(\.stringValue)
            pins.append(IntentPin(
                canonical: try selectorOf(pin["toolId"]!.stringValue!),
                policy: pin["policy"]?.stringValue == "exact" ? .exact : .elevated,
                threshold: pin["threshold"]?.doubleValue,
                aliases: phrases
            ))
        }

        let runtime = ToolRuntime(
            vectorIndex: MemoryVectorIndex(),
            embedder: AxisEmbedder(intent: intent, dimensions: dims),
            options: RuntimeOptions(dispatchConfig: config, llmClient: llm, intentPins: pins)
        )

        var classes: [String: ToolClass] = [:]
        var order: [String] = []
        for (i, tool) in tools.enumerated() {
            let id = tool["id"]!.stringValue!
            let score = Float(tool["score"]!.doubleValue!)
            let (providerId, toolName) = try parseToolId(id)
            var vector = [Float](repeating: 0, count: dims)
            vector[0] = score
            vector[i + 1] = (1 - score * score).squareRoot()
            let selector = try await runtime.selectorTable.register(embedding: vector, canonical: try selectorOf(id))
            var annotations: ToolAnnotations?
            if case .dict(let a)? = tool["annotations"] {
                annotations = ToolAnnotations(
                    readOnlyHint: a["readOnlyHint"]?.boolValue,
                    destructiveHint: a["destructiveHint"]?.boolValue
                )
            }
            let imp = CaseIMP(providerId: providerId, toolName: toolName, intent: intent, annotations: annotations)
            if classes[providerId] == nil {
                classes[providerId] = ToolClass(name: providerId)
                order.append(providerId)
            }
            classes[providerId]!.addMethod(selector, imp: imp)
        }
        for providerId in order { try await runtime.registerClass(classes[providerId]!) }
        return runtime
    }
}
