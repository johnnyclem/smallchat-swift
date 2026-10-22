import Foundation
import SmallChatCore
import SmallChatRuntime

/// A `JudgeContextProvider` that reads a running stenographer, so the
/// dispatch runtime's shortlist judge decides with the session's
/// tombstones and transcript in front of it: the truth entries most
/// relevant to the intent (`GET /truth/search`, falling back to the
/// current ledger), graded as the smallchat handoff says, and the newest
/// lines of the session. A stenographer that is down, slow or refuses
/// answers no context: the judge is then asked with the intent alone.
public struct StenographerJudgeContext: JudgeContextProvider {
    public let name = "stenographer"
    public let client: StenographerClient
    public let subject: String?
    public let limits: JudgeContextLimits
    public let timeout: TimeInterval

    public init(client: StenographerClient, subject: String? = nil, limits: JudgeContextLimits = .default, timeout: TimeInterval = 1.5) {
        self.client = client
        self.subject = subject
        self.limits = limits
        self.timeout = timeout
    }

    public func context(intent: String, principal: String?) async throws -> JudgeContext? {
        let client = self.client
        let limits = self.limits
        let subject = self.subject
        return await withTaskGroup(of: JudgeContext?.self) { group in
            group.addTask {
                async let truth = Self.truth(client, intent: intent, k: limits.maxTruth)
                async let transcript = Self.transcript(client, n: limits.maxTranscript)
                return boundJudgeContext(JudgeContext(subject: subject, truth: await truth, transcript: await transcript), limits: limits)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Entries graded for a judge, dead ones left out.
    public static func judgeEntries(_ entries: [StenographerTruthEntry]) -> [JudgeTruthEntry] {
        entries.compactMap { e in
            guard let grade = e.grade.flatMap(JudgeTruthGrade.init(rawValue:)) else { return nil }
            let literals = e.literals.map { JudgeTruthEntry.Literal(subject: $0.subject, dead: $0.dead, current: $0.current) }
            return JudgeTruthEntry(id: e.id, type: e.type, status: e.status, text: e.text, literals: literals.isEmpty ? nil : literals, grade: grade)
        }
    }

    private static func truth(_ client: StenographerClient, intent: String, k: Int) async -> [JudgeTruthEntry] {
        if let found = try? await client.searchTruth(String(intent.prefix(500)), k: k) { return judgeEntries(found) }
        if let all = try? await client.truth() { return judgeEntries(all) }
        return []
    }

    private static func transcript(_ client: StenographerClient, n: Int) async -> [JudgeTranscriptLine] {
        guard let messages = try? await client.recentMessages(n: n) else { return [] }
        // Newest first from the server; the judge reads oldest first
        return messages.reversed().compactMap { m in
            guard let role = JudgeTranscriptLine.Role(rawValue: m.role), !m.content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return JudgeTranscriptLine(role: role, text: m.content, id: m.id)
        }
    }
}
