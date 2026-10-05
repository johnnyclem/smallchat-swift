import Foundation
import SmallChatCore

/// Same cutoff `dispatch` uses when it stamps `metadata["ambiguous"]`: more
/// than one candidate and a winner at or under this score. Not a tier threshold.
public let ambiguousConfidence = 0.90

public let jevAbstain = "__none__"

public enum JevTrigger: String, Sendable {
    case lowConfidence = "low-confidence"
    case ambiguous
}

public struct JevCandidate: Sendable, Equatable {
    public var toolId: String
    public var description: String
    public var score: Double

    public init(toolId: String, description: String, score: Double) {
        self.toolId = toolId
        self.description = description
        self.score = score
    }
}

public struct JevVerdict: Sendable, Equatable {
    public var toolId: String?
    public var probability: Double
    public var confidence: Double?
    public var trigger: JevTrigger
    public var reason: String
}

/// Below HIGH, or the runtime's own ambiguous case. A winner above 0.90 is not asked.
public func jevTrigger(bestTier: DispatchTier, bestScore: Double, candidateCount: Int) -> JevTrigger? {
    if candidateCount > 1, bestScore <= ambiguousConfidence { return .ambiguous }
    if bestTier == .medium || bestTier == .low { return .lowConfidence }
    return nil
}

/// TypeSafe System One judge. Request shape matches `@typesafe-ai/sdk` 0.6.0:
/// POST `{base}/v1/systemone`, answer at `answers.tool` with
/// `{ type, choice, confidence, probabilities }`. An id is accepted only if it
/// was in the shortlist and its probability clears the threshold.
public struct JevJudge: Sendable {
    public var endpoint: URL
    public var model: String
    public var acceptThreshold: Double
    public var maxCandidates: Int
    public var timeout: TimeInterval
    private let apiKey: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        model: String = "jev-latest",
        acceptThreshold: Double = 0.7,
        maxCandidates: Int = 8,
        timeout: TimeInterval = 4,
        transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.acceptThreshold = acceptThreshold
        self.maxCandidates = maxCandidates
        self.timeout = timeout
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    public func judge(intent: String, candidates: [JevCandidate], trigger: JevTrigger) async -> JevVerdict {
        let shortlist = Array(candidates.prefix(maxCandidates))
        let allowed = Set(shortlist.map(\.toolId))
        guard !shortlist.isEmpty else {
            return JevVerdict(toolId: nil, probability: 0, confidence: nil, trigger: trigger, reason: "Jev was not asked: the shortlist was empty")
        }

        var criteria: [String: String] = [:]
        for candidate in shortlist {
            criteria[candidate.toolId] = String(candidate.description.prefix(240))
        }
        criteria[jevAbstain] = "None of these tools fit the intent"

        let answer: ChoiceAnswer
        do {
            answer = try await ask(intent: intent, criteria: criteria)
        } catch {
            return JevVerdict(toolId: nil, probability: 0, confidence: nil, trigger: trigger, reason: "Jev declined: \(error.localizedDescription)")
        }

        let choice = answer.choice ?? ""
        let probability = answer.probabilities?[choice] ?? 0
        if choice.isEmpty || choice == jevAbstain {
            return JevVerdict(toolId: nil, probability: probability, confidence: answer.confidence, trigger: trigger, reason: "Jev abstained: no shortlisted tool fit the intent")
        }
        guard allowed.contains(choice) else {
            return JevVerdict(toolId: nil, probability: probability, confidence: answer.confidence, trigger: trigger, reason: "Jev declined: \"\(choice)\" is not in the shortlist")
        }
        guard probability >= acceptThreshold else {
            return JevVerdict(toolId: nil, probability: probability, confidence: answer.confidence, trigger: trigger, reason: "Jev declined \(choice): probability \(probability) is below \(acceptThreshold)")
        }
        return JevVerdict(toolId: choice, probability: probability, confidence: answer.confidence, trigger: trigger, reason: "Jev approved \(choice) at \(probability) (\(trigger.rawValue))")
    }

    private func ask(intent: String, criteria: [String: String]) async throws -> ChoiceAnswer {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "state": intent,
            "questions": [
                "tool": [
                    "type": "choice",
                    "instructions": "Which registered tool should handle this intent? Pick __none__ if none fit.",
                    "criteria": criteria,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let parsed = try JSONDecoder().decode(SystemOneResponse.self, from: data)
        guard parsed.answers.tool.type == "choice" else {
            throw URLError(.cannotParseResponse)
        }
        return parsed.answers.tool
    }
}

private struct SystemOneResponse: Decodable {
    var answers: Answers
    struct Answers: Decodable { var tool: ChoiceAnswer }
}

private struct ChoiceAnswer: Decodable {
    var type: String
    var choice: String?
    var confidence: Double?
    var probabilities: [String: Double]?
}
