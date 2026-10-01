import Foundation
import Testing
import SmallChatCore

/// spec/ranking/vectors.json (smallchat.rank.v1): score quantization,
/// candidate order (ties by tool id, UTF-16 code units) and tiers.
@Suite("Conformance: ranking (spec/ranking)")
struct RankingVectorTests {
    static let spec = try! SpecFixtures.json("ranking/vectors.json")

    @Test("the vectors are smallchat.rank.v1")
    func version() {
        #expect(Self.spec["version"]?.stringValue == "smallchat.rank.v1")
    }

    @Test("quantizeScore", arguments: RankingVectorTests.spec["quantize"]!.arrayValue)
    func quantize(_ v: AnyCodableValue) throws {
        let input = try #require(v["input"]?.doubleValue)
        let expected = try #require(v["expected"]?.doubleValue)
        #expect(quantizeScore(input) == expected, "quantizeScore(\(input))")
    }

    @Test("candidate order", arguments: RankingVectorTests.spec["rank"]!.arrayValue)
    func rank(_ v: AnyCodableValue) throws {
        let candidates = try v["candidates"]!.arrayValue.map { c in
            (toolId: try #require(c["toolId"]?.stringValue), score: try #require(c["score"]?.doubleValue))
        }
        let expected = v["expected"]!.arrayValue.compactMap(\.stringValue)
        let order = { (list: [(toolId: String, score: Double)]) in
            list.sorted { rankedBefore(score: $0.score, toolId: $0.toolId, score: $1.score, toolId: $1.toolId) }.map(\.toolId)
        }
        #expect(order(candidates) == expected, "\(v["name"]?.stringValue ?? "")")
        #expect(order(candidates.reversed()) == expected, "\(v["name"]?.stringValue ?? "") (reversed input)")
    }

    @Test("tier of a quantized score, default thresholds", arguments: RankingVectorTests.spec["tier"]!.arrayValue)
    func tier(_ v: AnyCodableValue) throws {
        let score = try #require(v["score"]?.doubleValue)
        let expected = try #require(v["expected"]?.stringValue)
        #expect(computeTier(quantizeScore(score)).rawValue == expected, "tier(\(score))")
        #expect(DispatchConfig().tier(for: score).rawValue == expected, "DispatchConfig().tier(for: \(score))")
    }
}
