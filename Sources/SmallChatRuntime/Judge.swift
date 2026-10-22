import Foundation
import SmallChatCore

// MARK: - Shortlist judge (@smallchat/core 1.0 core/judge.ts; spec/judge)
//
// An optional tie-breaker for the dispatch pipeline (RuntimeOptions.judge).
// A judge is never an authority: the runtime decides when to ask it, what
// to offer it and what its answer may do; a judge only says which offered
// tool fits the intent. With the judge unset, dispatch is what it is
// without one; with it unreachable or failing, the decision is too, but
// the call waits up to the judge's `timeoutMs`, its proof records the
// attempt (so its digest differs) and it is not cached.
//
//   D1 When: never for an EXACT or NONE winner. A HIGH winner only when a
//      runner-up is within `margin` (ambiguous); a MEDIUM/LOW winner
//      always (low-confidence, or ambiguous with a near runner-up).
//   D2 What: near-ties of the winner the judge could choose and then run,
//      at most `maxCandidates`, presented sorted by tool id.
//   D3 Answers: approved (an offered id at probability >= acceptThreshold)
//      chooses it; declined is needs-disambiguation; unavailable decides
//      as without a judge.
//   D4 Records: decision codes judge-approved / judge-declined;
//      ResolutionProof.judge (a JudgeRecord); replay answers from the
//      record and never calls a judge; nothing a judge took part in is
//      cached.

/// Default `margin`: how close a runner-up must be to the winner to count as a near-tie.
public let defaultJudgeMargin = 0.05
/// Default `acceptThreshold`: the probability an approval needs on the chosen id.
public let defaultJudgeAccept = 0.7
/// Default `maxCandidates`: how many near-ties a judge is offered at most.
public let defaultJudgeMaxCandidates = 8
/// Default `timeoutMs`: how long the runtime waits for a judge's answer.
public let defaultJudgeTimeoutMs = 4000
/// Largest `timeoutMs` (the platform timer limit).
public let maxJudgeTimeoutMs = 2_147_483_647
/// A tool description offered to a judge is cut to this many UTF-16 code units.
public let judgeDescriptionChars = 240

/// Why the judge was asked.
public enum JudgeTrigger: String, Sendable, Codable, Equatable {
    case lowConfidence = "low-confidence"
    case ambiguous
}

/// One offered tool. The description is tool-server text: untrusted.
public struct JudgeCandidate: Sendable, Equatable, Codable {
    public var toolId: String
    public var description: String

    public init(toolId: String, description: String) {
        self.toolId = toolId
        self.description = description
    }
}

/// The grade of a truth entry offered as context (stenographer's handoff).
public enum JudgeTruthGrade: String, Sendable, Codable, Equatable {
    case verified, asserted, migration, advisory
}

/// One truth-ledger entry offered to a judge as context: a tombstone is a
/// fact a person signed, an unverified assertion is a flag.
public struct JudgeTruthEntry: Sendable, Equatable, Codable {
    public struct Literal: Sendable, Equatable, Codable {
        public var subject: String?
        public var dead: String
        public var current: String?
        public init(subject: String? = nil, dead: String, current: String? = nil) {
            self.subject = subject
            self.dead = dead
            self.current = current
        }
    }

    public var id: String
    /// `TB` or `UV`
    public var type: String
    public var status: String
    public var text: String
    public var literals: [Literal]?
    public var grade: JudgeTruthGrade?

    public init(id: String, type: String, status: String, text: String, literals: [Literal]? = nil, grade: JudgeTruthGrade? = nil) {
        self.id = id
        self.type = type
        self.status = status
        self.text = text
        self.literals = literals
        self.grade = grade
    }
}

/// One transcript line offered to a judge as context.
public struct JudgeTranscriptLine: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable, Equatable { case user, assistant, tool, system }
    public var role: Role
    public var text: String
    public var id: String?

    public init(role: Role, text: String, id: String? = nil) {
        self.role = role
        self.text = text
        self.id = id
    }
}

/// What a judge may be told besides the intent. Never recorded in a proof
/// (only that it was offered).
public struct JudgeContext: Sendable, Equatable, Codable {
    public var sessionId: String?
    public var subject: String?
    public var truth: [JudgeTruthEntry]?
    /// Oldest first
    public var transcript: [JudgeTranscriptLine]?

    public init(sessionId: String? = nil, subject: String? = nil, truth: [JudgeTruthEntry]? = nil, transcript: [JudgeTranscriptLine]? = nil) {
        self.sessionId = sessionId
        self.subject = subject
        self.truth = truth
        self.transcript = transcript
    }

    public var isEmpty: Bool {
        sessionId == nil && subject == nil && (truth?.isEmpty ?? true) && (transcript?.isEmpty ?? true)
    }
}

/// Bounds applied to a JudgeContext before it is sent (`boundJudgeContext`).
public struct JudgeContextLimits: Sendable, Equatable {
    public var maxTruth: Int
    public var maxTranscript: Int
    public var maxTextChars: Int

    public init(maxTruth: Int = 24, maxTranscript: Int = 12, maxTextChars: Int = 480) {
        self.maxTruth = maxTruth
        self.maxTranscript = maxTranscript
        self.maxTextChars = maxTextChars
    }

    public static let `default` = JudgeContextLimits()
}

/// Where a judge's context comes from (RuntimeOptions.judgeContext): asked
/// once per judged resolution, before the judge, within its time budget.
/// Nil, a throw or a timeout means the judge is asked with no context.
public protocol JudgeContextProvider: Sendable {
    /// Short stable name, recorded in the judge step's detail
    var name: String { get }
    func context(intent: String, principal: String?) async throws -> JudgeContext?
}

/// What the runtime asks a judge.
public struct JudgeRequest: Sendable, Equatable {
    public var intent: String
    public var trigger: JudgeTrigger
    /// The offered tools, sorted by tool id (never in rank order)
    public var candidates: [JudgeCandidate]
    /// Truth entries and transcript the judge may consider; nil without a provider
    public var context: JudgeContext?

    public init(intent: String, trigger: JudgeTrigger, candidates: [JudgeCandidate], context: JudgeContext? = nil) {
        self.intent = intent
        self.trigger = trigger
        self.candidates = candidates
        self.context = context
    }
}

/// Why a judge gave no usable answer.
public enum JudgeErrorCode: Sendable, Equatable, Hashable {
    case auth, rateLimited, timeout, network, malformed, aborted
    case http(Int)

    public var rawValue: String {
        switch self {
        case .auth: return "AUTH"
        case .rateLimited: return "RATE_LIMITED"
        case .timeout: return "TIMEOUT"
        case .network: return "NETWORK"
        case .malformed: return "MALFORMED"
        case .aborted: return "ABORTED"
        case .http(let status): return "HTTP_\(status)"
        }
    }

    /// The code a string names, or nil when it is not one.
    public init?(rawValue: String) {
        switch rawValue {
        case "AUTH": self = .auth
        case "RATE_LIMITED": self = .rateLimited
        case "TIMEOUT": self = .timeout
        case "NETWORK": self = .network
        case "MALFORMED": self = .malformed
        case "ABORTED": self = .aborted
        default:
            guard rawValue.hasPrefix("HTTP_"), let status = Int(rawValue.dropFirst(5)), (100...999).contains(status),
                  String(status) == String(rawValue.dropFirst(5)) else { return nil }
            self = .http(status)
        }
    }
}

/// What a judge answered, before the runtime accepts or declines it.
public enum JudgeAnswer: Sendable, Equatable {
    /// `choice` nil: abstain. `model`: the model that answered, when reported.
    case answered(choice: String?, probability: Double?, confidence: Double?, model: String? = nil, requestId: String? = nil)
    case unavailable(error: JudgeErrorCode, retryAfterMs: Int? = nil, model: String? = nil, requestId: String? = nil)
}

/// A shortlist judge. `name` and `model` are recorded in every proof the
/// judge takes part in. `judge` should not throw (a throw counts as
/// unavailable); the runtime holds every judge to its `timeoutMs` by
/// cancelling the task it runs in.
public protocol ShortlistJudge: Sendable {
    var name: String { get }
    var model: String { get }
    /// Near-tie margin, in [0, 1). Default defaultJudgeMargin.
    var margin: Double? { get }
    /// Most tools offered, an integer >= 1. Default defaultJudgeMaxCandidates.
    var maxCandidates: Int? { get }
    /// Probability an approval needs, in (0, 1]. Default defaultJudgeAccept.
    var acceptThreshold: Double? { get }
    /// Milliseconds the runtime waits for an answer. Default defaultJudgeTimeoutMs.
    var timeoutMs: Int? { get }
    func judge(_ request: JudgeRequest) async -> JudgeAnswer
    /// Told how a judged decision turned out (ToolRuntime.gradeJudgement). Optional.
    func feedback(_ grade: JudgeFeedback) async throws
}

extension ShortlistJudge {
    public var margin: Double? { nil }
    public var maxCandidates: Int? { nil }
    public var acceptThreshold: Double? { nil }
    public var timeoutMs: Int? { nil }
    public func feedback(_ grade: JudgeFeedback) async throws {}
}

/// A judge's settings, validated (`judgeSettings`).
public struct JudgeSettings: Sendable, Equatable {
    public var margin: Double
    public var maxCandidates: Int
    public var acceptThreshold: Double
    public var timeoutMs: Int

    public init(margin: Double = defaultJudgeMargin, maxCandidates: Int = defaultJudgeMaxCandidates, acceptThreshold: Double = defaultJudgeAccept, timeoutMs: Int = defaultJudgeTimeoutMs) {
        self.margin = margin
        self.maxCandidates = maxCandidates
        self.acceptThreshold = acceptThreshold
        self.timeoutMs = timeoutMs
    }
}

/// A judge setting out of range.
public struct JudgeSettingsError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Decline reasons (D3).
public enum JudgeDeclineReason: String, Sendable {
    case abstained
    case outsideShortlist = "outside-shortlist"
    case belowThreshold = "below-threshold"
}

/// An answer, accepted or not (`acceptJudgeAnswer`).
public struct JudgeVerdict: Sendable, Equatable {
    public var verdict: JudgeRecord.Verdict
    /// The offered tool it approved; nil unless approved
    public var toolId: String?
    public var probability: Double?
    public var confidence: Double?
    /// The model that answered, else the configured one
    public var model: String
    /// `approved`, a decline reason or an error code; nil only for a replayed record that carried none
    public var reason: String?
    public var requestId: String?
}

/// A recorded verdict that answers in a judge's place (`ResolveOptions.judge`,
/// a decision-log line's `judge`). Only `verdict` is required; `toolId` is
/// required to approve. What it leaves out is never borrowed from the
/// runtime's judge: the proof records name `recorded`, model `unknown` and
/// a nil reason (spec/judge D4).
public struct RecordedJudgeVerdict: Sendable, Equatable, Codable {
    public var verdict: JudgeRecord.Verdict
    public var toolId: String?
    public var name: String?
    public var model: String?
    public var probability: Double?
    public var confidence: Double?
    public var reason: String?
    public var margin: Double?
    public var maxCandidates: Int?
    public var requestId: String?

    public init(verdict: JudgeRecord.Verdict, toolId: String? = nil, name: String? = nil, model: String? = nil, probability: Double? = nil, confidence: Double? = nil, reason: String? = nil, margin: Double? = nil, maxCandidates: Int? = nil, requestId: String? = nil) {
        self.verdict = verdict
        self.toolId = toolId
        self.name = name
        self.model = model
        self.probability = probability
        self.confidence = confidence
        self.reason = reason
        self.margin = margin
        self.maxCandidates = maxCandidates
        self.requestId = requestId
    }

    /// A proof's record, replayed as it was made.
    public init(_ record: JudgeRecord) {
        self.init(verdict: record.verdict, toolId: record.toolId, name: record.name, model: record.model, probability: record.probability,
                  confidence: record.confidence, reason: record.reason, margin: record.margin, maxCandidates: record.maxCandidates, requestId: record.requestId)
    }

    /// A recorded verdict in its JSON shape (a decision-log line's `judge`, a trace case's), or nil.
    public init?(json: AnyCodableValue) {
        guard case .dict(let v) = json, case .string(let verdictRaw)? = v["verdict"], let verdict = JudgeRecord.Verdict(rawValue: verdictRaw) else { return nil }
        func string(_ key: String) -> String?? {
            switch v[key] {
            case nil, .null?: return .some(nil)
            case .string(let s)?: return .some(s)
            default: return nil
            }
        }
        func number(_ key: String) -> Double?? {
            switch v[key] {
            case nil, .null?: return .some(nil)
            case .int(let i)?: return .some(Double(i))
            case .double(let d)?: return .some(d)
            default: return nil
            }
        }
        guard let toolId = string("toolId"), let name = string("name"), let model = string("model"), let reason = string("reason"), let requestId = string("requestId"),
              let probability = number("probability"), let confidence = number("confidence"), let margin = number("margin"), let maxCandidates = number("maxCandidates")
        else { return nil }
        if verdict == .approved && toolId == nil { return nil }
        self.init(verdict: verdict, toolId: toolId, name: name, model: model, probability: probability, confidence: confidence, reason: reason,
                  margin: margin, maxCandidates: maxCandidates.map { Int($0) }, requestId: requestId)
    }
}

/// How a judged decision was graded.
public enum JudgeGradeOutcome: String, Sendable, Codable, Equatable {
    case rewarded, corrected
}

/// What a graded judgement tells the judge and the decision log
/// (`ToolRuntime.gradeJudgement`).
public struct JudgeFeedback: Sendable, Equatable {
    public var outcome: JudgeGradeOutcome
    public var intent: String
    /// proofDigest of the graded resolution
    public var proofDigest: String
    /// The judge's part in it (the proof's record)
    public var judge: JudgeRecord
    public var chosenToolId: String?
    /// The tool that was right, when the caller said (the chosen one when rewarded)
    public var correctToolId: String?
    public var reason: String?
    public var principal: String?
}

// MARK: - Rules

/// JavaScript's Math.round: half rounds toward positive infinity.
private func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

/// Whether `score` is within `margin` of `best`, compared at the score quantum (1e-4).
public func withinJudgeMargin(best: Double, score: Double, margin: Double) -> Bool {
    jsRound((best - score) * 1e4) <= jsRound(margin * 1e4)
}

/// D1: whether to ask the judge, and why. `tier` is the winner's tier under
/// the runtime's thresholds; `runnerUpScore` is the second-ranked
/// candidate's score (nil when there is none).
public func judgeTrigger(tier: DispatchTier, bestScore: Double, runnerUpScore: Double?, margin: Double) -> JudgeTrigger? {
    if tier == .exact || tier == .none { return nil }
    let nearTie = runnerUpScore.map { withinJudgeMargin(best: bestScore, score: $0, margin: margin) } ?? false
    if tier == .high { return nearTie ? .ambiguous : nil }
    return nearTie ? .ambiguous : .lowConfidence
}

private func isControl(_ unit: UInt16) -> Bool {
    unit <= 0x1F || (0x7F...0x9F).contains(unit) || unit == 0x2028 || unit == 0x2029
}

/// Text with every run of control characters and line or paragraph
/// separators replaced by one space, then cut to `maxUnits` UTF-16 code
/// units; a cut never splits a surrogate pair.
public func foldJudgeText(_ text: String, maxUnits: Int) -> String {
    var folded: [UInt16] = []
    folded.reserveCapacity(text.utf16.count)
    var inRun = false
    for unit in text.utf16 {
        if isControl(unit) {
            if !inRun { folded.append(0x20) }
            inRun = true
        } else {
            folded.append(unit)
            inRun = false
        }
    }
    if folded.count > maxUnits {
        var cut = maxUnits
        if cut > 0, (0xD800...0xDBFF).contains(folded[cut - 1]), cut < folded.count, (0xDC00...0xDFFF).contains(folded[cut]) { cut -= 1 }
        folded.removeSubrange(cut...)
    }
    return String(decoding: folded, as: UTF16.self)
}

/// A tool description as offered to a judge (D2 item 5).
public func judgeDescription(_ text: String) -> String {
    foldJudgeText(text, maxUnits: judgeDescriptionChars)
}

/// Tool ids in UTF-16 code unit order (the order candidates are presented in).
public func judgeToolIdPrecedes(_ a: String, _ b: String) -> Bool {
    Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
}

/// A judge's settings, defaulted and validated. Throws on a value out of range.
public func judgeSettings(margin: Double? = nil, maxCandidates: Int? = nil, acceptThreshold: Double? = nil, timeoutMs: Int? = nil) throws -> JudgeSettings {
    let margin = margin ?? defaultJudgeMargin
    let maxCandidates = maxCandidates ?? defaultJudgeMaxCandidates
    let acceptThreshold = acceptThreshold ?? defaultJudgeAccept
    let timeoutMs = timeoutMs ?? defaultJudgeTimeoutMs
    guard margin.isFinite, margin >= 0, margin < 1 else { throw JudgeSettingsError(message: "judge margin must be a number in [0, 1), got \(margin)") }
    guard maxCandidates >= 1 else { throw JudgeSettingsError(message: "judge maxCandidates must be an integer >= 1, got \(maxCandidates)") }
    guard acceptThreshold.isFinite, acceptThreshold > 0, acceptThreshold <= 1 else { throw JudgeSettingsError(message: "judge acceptThreshold must be a number in (0, 1], got \(acceptThreshold)") }
    guard timeoutMs > 0, timeoutMs <= maxJudgeTimeoutMs else { throw JudgeSettingsError(message: "judge timeoutMs must be a positive number of milliseconds up to \(maxJudgeTimeoutMs), got \(timeoutMs)") }
    return JudgeSettings(margin: margin, maxCandidates: maxCandidates, acceptThreshold: acceptThreshold, timeoutMs: timeoutMs)
}

/// The settings of a configured judge, validated.
public func judgeSettings(of judge: any ShortlistJudge) throws -> JudgeSettings {
    try judgeSettings(margin: judge.margin, maxCandidates: judge.maxCandidates, acceptThreshold: judge.acceptThreshold, timeoutMs: judge.timeoutMs)
}

/// A plain model name: an ASCII letter or digit, then up to 99 of [A-Za-z0-9._:/@-].
public func isJudgeModelName(_ s: String) -> Bool {
    let units = Array(s.utf8)
    guard !units.isEmpty, units.count <= 100 else { return false }
    func alnum(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
    guard alnum(units[0]) else { return false }
    return units.dropFirst().allSatisfy { alnum($0) || "._:/@-".utf8.contains($0) }
}

/// A provider request id is recorded only in this shape: 1 to 128 of [A-Za-z0-9._-].
public func isJudgeRequestId(_ s: String) -> Bool {
    let units = Array(s.utf8)
    guard !units.isEmpty, units.count <= 128 else { return false }
    return units.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || "._-".utf8.contains($0) }
}

private func unit(_ value: Double?) -> Double?? {
    guard let value else { return .some(nil) }
    return value.isFinite && value >= 0 && value <= 1 ? .some(value) : nil
}

/// D3: accept or decline what a judge answered. Approved only for an
/// `offered` id whose probability is at least `acceptThreshold` (a threshold
/// outside (0, 1] approves nothing); an answer outside the contract (a
/// number outside [0, 1]) is unavailable (`MALFORMED`).
public func acceptJudgeAnswer(_ answer: JudgeAnswer, offered: [String], acceptThreshold: Double, configuredModel: String) -> JudgeVerdict {
    func modelOf(_ reported: String?) -> String {
        if let reported, isJudgeModelName(reported) { return reported }
        return configuredModel
    }
    func idOf(_ reported: String?) -> String? {
        if let reported, isJudgeRequestId(reported) { return reported }
        return nil
    }
    switch answer {
    case .unavailable(let error, _, let model, let requestId):
        return JudgeVerdict(verdict: .unavailable, toolId: nil, probability: nil, confidence: nil, model: modelOf(model), reason: error.rawValue, requestId: idOf(requestId))
    case .answered(let choice, let probabilityRaw, let confidenceRaw, let model, let requestId):
        let recordedModel = modelOf(model)
        let id = idOf(requestId)
        guard let probability = unit(probabilityRaw), let confidence = unit(confidenceRaw) else {
            return JudgeVerdict(verdict: .unavailable, toolId: nil, probability: nil, confidence: nil, model: recordedModel, reason: JudgeErrorCode.malformed.rawValue, requestId: id)
        }
        func declined(_ reason: JudgeDeclineReason) -> JudgeVerdict {
            JudgeVerdict(verdict: .declined, toolId: nil, probability: probability, confidence: confidence, model: recordedModel, reason: reason.rawValue, requestId: id)
        }
        guard let choice else { return declined(.abstained) }
        guard offered.contains(choice) else { return declined(.outsideShortlist) }
        // Fail closed: a threshold outside (0, 1] approves nothing.
        let threshold = acceptThreshold.isFinite && acceptThreshold > 0 && acceptThreshold <= 1 ? acceptThreshold : Double.nan
        guard let p = probability, p >= threshold else { return declined(.belowThreshold) }
        return JudgeVerdict(verdict: .approved, toolId: choice, probability: probability, confidence: confidence, model: recordedModel, reason: "approved", requestId: id)
    }
}

/// A recorded verdict replayed against the shortlist rebuilt now (D4). An
/// approval of an id that is no longer offered is declined
/// (`outside-shortlist`); an approval is not checked against a threshold
/// again. A decline or an unavailable record without a valid reason
/// replays with none.
public func replayJudgeVerdict(_ recorded: RecordedJudgeVerdict, offered: [String], model: String) -> JudgeVerdict {
    let probability = unit(recorded.probability) ?? nil
    let confidence = unit(recorded.confidence) ?? nil
    switch recorded.verdict {
    case .approved:
        if let toolId = recorded.toolId, offered.contains(toolId) {
            return JudgeVerdict(verdict: .approved, toolId: toolId, probability: probability, confidence: confidence, model: model, reason: "approved")
        }
        return JudgeVerdict(verdict: .declined, toolId: nil, probability: probability, confidence: confidence, model: model, reason: JudgeDeclineReason.outsideShortlist.rawValue)
    case .declined:
        let reason = recorded.reason.flatMap { JudgeDeclineReason(rawValue: $0)?.rawValue }
        return JudgeVerdict(verdict: .declined, toolId: nil, probability: probability, confidence: confidence, model: model, reason: reason)
    case .unavailable:
        let reason = recorded.reason.flatMap { JudgeErrorCode(rawValue: $0)?.rawValue }
        return JudgeVerdict(verdict: .unavailable, toolId: nil, probability: probability, confidence: confidence, model: model, reason: reason)
    }
}

/// The settings a recorded verdict was made with, else the runtime's, else the defaults.
public func recordedJudgeSettings(_ recorded: RecordedJudgeVerdict, configured: JudgeSettings?) -> JudgeSettings {
    let fallback = configured ?? JudgeSettings()
    return (try? judgeSettings(margin: recorded.margin ?? fallback.margin, maxCandidates: recorded.maxCandidates ?? fallback.maxCandidates,
                               acceptThreshold: fallback.acceptThreshold, timeoutMs: fallback.timeoutMs)) ?? fallback
}

private let truthGradeOrder: [JudgeTruthGrade: Int] = [.verified: 0, .asserted: 1, .migration: 2, .advisory: 3]

/// A JudgeContext as a judge may send it: every text folded to one line and
/// cut, truth entries kept best grade first up to `maxTruth`, the newest
/// `maxTranscript` transcript lines kept. Nil when nothing is left.
public func boundJudgeContext(_ context: JudgeContext?, limits: JudgeContextLimits = .default) -> JudgeContext? {
    guard let context else { return nil }
    var out = JudgeContext()
    if let session = context.sessionId, !session.isEmpty { out.sessionId = foldJudgeText(session, maxUnits: 128) }
    if let subject = context.subject, !subject.isEmpty { out.subject = foldJudgeText(subject, maxUnits: limits.maxTextChars) }
    let truth = (context.truth ?? [])
        .filter { ($0.type == "TB" || $0.type == "UV") }
        .enumerated()
        .sorted { a, b in
            let ga = a.element.grade.flatMap { truthGradeOrder[$0] } ?? 4
            let gb = b.element.grade.flatMap { truthGradeOrder[$0] } ?? 4
            return ga != gb ? ga < gb : a.offset < b.offset
        }
        .prefix(max(0, limits.maxTruth))
        .map { entry -> JudgeTruthEntry in
            let e = entry.element
            let literals = (e.literals ?? []).prefix(16).map {
                JudgeTruthEntry.Literal(subject: $0.subject.map { foldJudgeText($0, maxUnits: 128) }, dead: foldJudgeText($0.dead, maxUnits: 128), current: $0.current.map { foldJudgeText($0, maxUnits: 128) })
            }
            return JudgeTruthEntry(id: foldJudgeText(e.id, maxUnits: 128), type: e.type, status: foldJudgeText(e.status, maxUnits: 32),
                                   text: foldJudgeText(e.text, maxUnits: limits.maxTextChars), literals: literals.isEmpty ? nil : Array(literals), grade: e.grade)
        }
    if !truth.isEmpty { out.truth = truth }
    let transcript = (context.transcript ?? []).suffix(max(0, limits.maxTranscript)).map {
        JudgeTranscriptLine(role: $0.role, text: foldJudgeText($0.text, maxUnits: limits.maxTextChars), id: $0.id.map { foldJudgeText($0, maxUnits: 128) })
    }
    if !transcript.isEmpty { out.transcript = transcript }
    return out.isEmpty ? nil : out
}
