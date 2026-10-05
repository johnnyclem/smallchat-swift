import Foundation
import Testing
@testable import SmallChatCore

/// smallchat-swift has no shortlist judge, but TypeScript proofs may carry
/// one's decision codes, step and record (smallchat spec/judge, D4).
@Suite("JudgeRecord")
struct JudgeRecordTests {

    /// A proof @smallchat/core 1.0 wrote (dist build of smallchat
    /// claude/jev-judge-review) where a stub judge chose the runner-up of a
    /// HIGH near-tie.
    static let approvedProof = #"""
    {
      "version": 1,
      "intent": "look up issue 7",
      "outcome": "resolved",
      "decision": "judge-approved",
      "tier": "high",
      "chosen": "gitlab/get_issue",
      "confidence": 0.88,
      "ran": null,
      "callDigest": null,
      "resolutionDigest": null,
      "candidates": [
        {
          "toolId": "github/get_issue",
          "selector": "github.get_issue",
          "score": 0.9,
          "similarity": 0.9,
          "tier": "high",
          "source": "vector"
        },
        {
          "toolId": "gitlab/get_issue",
          "selector": "gitlab.get_issue",
          "score": 0.88,
          "similarity": 0.88,
          "tier": "high",
          "source": "vector"
        }
      ],
      "thresholds": {
        "exact": 0.95,
        "high": 0.85,
        "medium": 0.75,
        "low": 0.6
      },
      "guards": {
        "requireLLMForSubHighDispatch": true,
        "strict": false,
        "llmVerifier": false,
        "treatUnannotatedAsDestructive": false
      },
      "embedder": null,
      "artifactHash": null,
      "steps": [
        {
          "stage": "vector_search",
          "decision": "Vector search found 2 candidate tool(s) at or above 0.6",
          "detail": {
            "floor": 0.6,
            "matches": [
              {
                "selector": "github.get_issue",
                "similarity": 0.9
              },
              {
                "selector": "gitlab.get_issue",
                "similarity": 0.88
              }
            ]
          }
        },
        {
          "stage": "judge",
          "decision": "judge-approved: stub (stub-1) chose gitlab/get_issue from 2 offered (ambiguous)",
          "detail": {
            "judge": "stub",
            "model": "stub-1",
            "verdict": "approved",
            "toolId": "gitlab/get_issue",
            "trigger": "ambiguous",
            "offered": [
              "github/get_issue",
              "gitlab/get_issue"
            ]
          }
        },
        {
          "stage": "policy",
          "decision": "gitlab/get_issue allowed at high (0.880)",
          "detail": {
            "code": "allow",
            "toolId": "gitlab/get_issue"
          }
        }
      ],
      "timings": {
        "totalMs": 3.785065999999972,
        "stepsMs": [
          2.00881099999998,
          1.7220490000000268,
          0.054205999999965115
        ]
      },
      "proofDigest": "8aede58f1726fd4f30973178a531c2f4cccb3f311247b8329a553144fe61abae",
      "judge": {
        "name": "stub",
        "model": "stub-1",
        "verdict": "approved",
        "toolId": "gitlab/get_issue",
        "probability": 0.93,
        "confidence": 0.8,
        "reason": "approved",
        "margin": 0.05,
        "maxCandidates": 8,
        "requestId": "req_1"
      }
    }
    """#

    /// The same near-tie, where the stub judge abstained.
    static let declinedProof = #"""
    {
      "version": 1,
      "intent": "look up issue 7",
      "outcome": "needs-disambiguation",
      "decision": "judge-declined",
      "tier": "high",
      "chosen": null,
      "confidence": null,
      "ran": null,
      "callDigest": null,
      "resolutionDigest": null,
      "candidates": [
        {
          "toolId": "github/get_issue",
          "selector": "github.get_issue",
          "score": 0.9,
          "similarity": 0.9,
          "tier": "high",
          "source": "vector"
        },
        {
          "toolId": "gitlab/get_issue",
          "selector": "gitlab.get_issue",
          "score": 0.88,
          "similarity": 0.88,
          "tier": "high",
          "source": "vector"
        }
      ],
      "thresholds": {
        "exact": 0.95,
        "high": 0.85,
        "medium": 0.75,
        "low": 0.6
      },
      "guards": {
        "requireLLMForSubHighDispatch": true,
        "strict": false,
        "llmVerifier": false,
        "treatUnannotatedAsDestructive": false
      },
      "embedder": null,
      "artifactHash": null,
      "steps": [
        {
          "stage": "vector_search",
          "decision": "Vector search found 2 candidate tool(s) at or above 0.6",
          "detail": {
            "floor": 0.6,
            "matches": [
              {
                "selector": "github.get_issue",
                "similarity": 0.9
              },
              {
                "selector": "gitlab.get_issue",
                "similarity": 0.88
              }
            ]
          }
        },
        {
          "stage": "judge",
          "decision": "judge-declined: stub (stub-1) chose none of the 2 offered (ambiguous)",
          "detail": {
            "judge": "stub",
            "model": "stub-1",
            "verdict": "declined",
            "toolId": null,
            "trigger": "ambiguous",
            "offered": [
              "github/get_issue",
              "gitlab/get_issue"
            ]
          }
        }
      ],
      "timings": {
        "totalMs": 3.203399999999988,
        "stepsMs": [
          1.6437649999999735,
          1.5596350000000143
        ]
      },
      "proofDigest": "03608825de2d90ab956cd3460a9dc826bbf24119777ad493e33af96b2b1c4471",
      "judge": {
        "name": "stub",
        "model": "stub-1",
        "verdict": "declined",
        "toolId": null,
        "probability": 0.7,
        "confidence": 0.6,
        "reason": "abstained",
        "margin": 0.05,
        "maxCandidates": 8
      }
    }
    """#

    static func decode(_ json: String) throws -> ResolutionProof {
        try JSONDecoder().decode(ResolutionProof.self, from: Data(json.utf8))
    }

    @Test("Decodes a TypeScript proof with judge-approved, a judge step and its record")
    func decodesApproved() throws {
        let proof = try Self.decode(Self.approvedProof)
        #expect(proof.decision == .judgeApproved)
        #expect(proof.chosen == "gitlab/get_issue")
        #expect(proof.steps.map(\.stage) == [.vectorSearch, .judge, .policy])
        let judge = try #require(proof.judge)
        #expect(judge == JudgeRecord(
            name: "stub", model: "stub-1", verdict: .approved, toolId: "gitlab/get_issue",
            probability: 0.93, confidence: 0.8, reason: "approved", margin: 0.05, maxCandidates: 8,
            requestId: "req_1"
        ))

        let again = try JSONDecoder().decode(ResolutionProof.self, from: JSONEncoder().encode(proof))
        #expect(again == proof)
    }

    @Test("Recomputes TypeScript's proofDigest for proofs with a judge record")
    func digestMatchesTypeScript() throws {
        let approved = try Self.decode(Self.approvedProof)
        #expect(approved.computeDigest() == approved.proofDigest)
        let declined = try Self.decode(Self.declinedProof)
        #expect(declined.computeDigest() == declined.proofDigest)
    }

    @Test("Decodes judge-declined with a null tool id, and a replayed record's null reason")
    func decodesDeclined() throws {
        let proof = try Self.decode(Self.declinedProof)
        #expect(proof.decision == .judgeDeclined)
        #expect(proof.outcome == .needsDisambiguation)
        #expect(proof.judge?.verdict == .declined)
        #expect(proof.judge?.toolId == nil)
        #expect(proof.judge?.reason == "abstained")
        #expect(proof.judge?.requestId == nil)

        let replayed = try Self.decode(
            Self.declinedProof.replacingOccurrences(of: #""reason": "abstained""#, with: #""reason": null"#)
        )
        #expect(replayed.judge?.reason == nil)
        guard case .dict(let object) = replayed.jsonValue, case .dict(let judge) = object["judge"] else {
            Issue.record("the encoded proof has no judge object")
            return
        }
        #expect(judge["toolId"] == .null)
        #expect(judge["reason"] == .null)
        #expect(judge["requestId"] == nil)
    }

    @Test("A verdict outside approved, declined and unavailable fails to decode")
    func unknownVerdictFailsClosed() {
        let unknown = Self.approvedProof.replacingOccurrences(of: #""verdict": "approved""#, with: #""verdict": "maybe""#)
        #expect(throws: DecodingError.self) { try Self.decode(unknown) }
    }

    @Test("proofDigest covers the judge's name, model, verdict and toolId only")
    func digestCoversDigestedFields() throws {
        let proof = try Self.decode(Self.approvedProof)
        let digest = proof.computeDigest()

        var noisy = proof
        noisy.judge?.probability = 0.55
        noisy.judge?.confidence = nil
        noisy.judge?.reason = "below-threshold"
        noisy.judge?.margin = 0.2
        noisy.judge?.maxCandidates = 3
        noisy.judge?.requestId = nil
        #expect(noisy.computeDigest() == digest)

        var otherModel = proof
        otherModel.judge?.model = "stub-2"
        #expect(otherModel.computeDigest() != digest)

        var otherTool = proof
        otherTool.judge?.toolId = "github/get_issue"
        #expect(otherTool.computeDigest() != digest)

        var withoutJudge = proof
        withoutJudge.judge = nil
        #expect(withoutJudge.computeDigest() != digest)
        #expect(withoutJudge.bodyJSON["judge"] == nil)
        #expect(proof.bodyJSON["judge"] == proof.judge?.jsonValue)
    }
}
