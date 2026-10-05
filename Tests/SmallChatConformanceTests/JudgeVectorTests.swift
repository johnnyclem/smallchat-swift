import Foundation
import Testing
import SmallChatCore

/// spec/judge/vectors.json (smallchat.judge.v1). This runtime has no
/// shortlist judge, so it does not run the trigger, resolve, replay or wire
/// sections. Until it does, the spec requires it to decode what TypeScript
/// proofs record about a judge: the decision codes, the `judge` step and
/// `proof.judge`. Each resolve and replay case's expectation, put in a
/// proof's shape, must decode to the values it states.
@Suite("Conformance: shortlist judge records (spec/judge)")
struct JudgeVectorTests {
    static let spec = try! SpecFixtures.json("judge/vectors.json")
    static let cases = spec["resolve"]!.arrayValue + spec["replay"]!.arrayValue

    @Test("the vectors are smallchat.judge.v1")
    func version() {
        #expect(Self.spec["version"]?.stringValue == "smallchat.judge.v1")
    }

    @Test("every resolve and replay expectation decodes as a proof", arguments: JudgeVectorTests.cases)
    func decodesExpectation(_ c: AnyCodableValue) throws {
        let name = c["name"]?.stringValue ?? "?"
        let expect = try #require(c["expect"])
        let defaults = try #require(Self.spec["defaults"])

        let outcome = try #require(expect["outcome"])
        let decision = try #require(expect["decision"])
        let tier = try #require(expect["tier"])
        var body: [String: AnyCodableValue] = [
            "version": .int(1),
            "outcome": outcome,
            "decision": decision,
            "tier": tier,
            "chosen": expect["chosen"] ?? .null,
        ]
        if let step = expect["step"], !step.isNull {
            var judgeStep: [String: AnyCodableValue] = ["stage": .string("judge"), "decision": step["decision"] ?? .null]
            if let detail = step["detail"] { judgeStep["detail"] = detail }
            body["steps"] = .array([.dict(judgeStep)])
        }
        let judge = expect["judge"] ?? .null
        let record = expect["record"]
        if !judge.isNull {
            var stored: [String: AnyCodableValue] = [:]
            for key in ["name", "model", "verdict", "toolId"] {
                stored[key] = judge[key] ?? .null
            }
            for key in ["probability", "confidence", "reason"] {
                stored[key] = record?[key] ?? .null
            }
            for key in ["margin", "maxCandidates"] {
                stored[key] = record?[key] ?? defaults[key] ?? .null
            }
            body["judge"] = .dict(stored)
        }

        let proof = try JSONDecoder().decode(ResolutionProof.self, from: JSONEncoder().encode(AnyCodableValue.dict(body)))
        #expect(proof.decision.rawValue == expect["decision"]?.stringValue, "\(name): decision")
        #expect(proof.outcome.rawValue == expect["outcome"]?.stringValue, "\(name): outcome")
        #expect(proof.tier.rawValue == expect["tier"]?.stringValue, "\(name): tier")
        if body["steps"] != nil {
            #expect(proof.steps.map(\.stage) == [.judge], "\(name): step")
        }
        if judge.isNull {
            #expect(proof.judge == nil, "\(name): judge")
            return
        }
        let decoded = try #require(proof.judge, "\(name): judge")
        #expect(decoded.name == judge["name"]?.stringValue, "\(name): judge name")
        #expect(decoded.model == judge["model"]?.stringValue, "\(name): judge model")
        #expect(decoded.verdict.rawValue == judge["verdict"]?.stringValue, "\(name): judge verdict")
        #expect(decoded.toolId == judge["toolId"]?.stringValue, "\(name): judge toolId")
        if let record {
            #expect(decoded.reason == record["reason"]?.stringValue, "\(name): reason")
            #expect(decoded.probability == record["probability"]?.doubleValue, "\(name): probability")
            #expect(decoded.confidence == record["confidence"]?.doubleValue, "\(name): confidence")
            #expect(decoded.margin == record["margin"]?.doubleValue, "\(name): margin")
            #expect(Double(decoded.maxCandidates) == record["maxCandidates"]?.doubleValue, "\(name): maxCandidates")
        }
    }
}
