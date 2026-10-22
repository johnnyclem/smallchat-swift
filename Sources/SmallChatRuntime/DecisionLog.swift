import Foundation
import SmallChatCore

// MARK: - Decision log (@smallchat/core 1.0 runtime/decision-log.ts)
//
// An optional, durable, append-only record of every resolution and
// dispatch a runtime makes (RuntimeOptions.decisionLog). One JSON object
// per line (JSONL), hash-chained in the same shape as the suite's truth
// format: `seq` starts at 1 and increases by one per line; `prevHash` is
// the previous line's `hash` (nil on seq 1, only there); `hash` =
// sha256hex(UTF8(JCS(line without `hash`))); `schema` is
// "smallchat.decision.v1" on every line. `verifyDecisionLog` checks all of
// that. The lines a TypeScript runtime writes verify here and the other way
// round: the shape, the digests and the chain are the same.
//
// A runtime writes the line for a dispatch before the tool executes. If a
// line cannot be written, the call throws and nothing executes. One writer
// per file.

/// `schema` value of every decision-log line.
public let decisionLogSchema = "smallchat.decision.v1"
/// Domain-separation prefix of the intent digest.
public let intentDigestDomain = "smallchat.intent.v1"

/// What kind of call a line records. A `judge-feedback` line records how a
/// caller graded a judged decision (`ToolRuntime.gradeJudgement`); replay skips it.
public enum DecisionKind: String, Sendable, Codable, Equatable {
    case resolve
    case dispatch
    case dispatchById = "dispatch-by-id"
    case judgeFeedback = "judge-feedback"
}

/// What happened after the decision.
public enum DecisionExecution: String, Sendable, Codable, Equatable {
    case none
    case ran
    case invalidArguments = "invalid-arguments"
    case aborted
    case decomposed
}

/// How a judged decision was graded (a `judge-feedback` line).
public struct DecisionFeedback: Sendable, Equatable {
    public var outcome: JudgeGradeOutcome
    public var correctToolId: String?
    public var reason: String?

    public init(outcome: JudgeGradeOutcome, correctToolId: String?, reason: String? = nil) {
        self.outcome = outcome
        self.correctToolId = correctToolId
        self.reason = reason
    }
}

/// One line of a decision log.
public struct DecisionRecord: Sendable, Equatable {
    public var seq: Int
    /// ISO 8601 UTC time the line was written
    public var ts: String
    public var kind: DecisionKind
    /// The intent text (nil when the log records digests only)
    public var intent: String?
    /// intentDigest(intent), or nil for a dispatch by id
    public var intentDigest: String?
    public var principal: String?
    public var artifactHash: String?
    public var embedderFingerprint: EmbedderFingerprint?
    public var outcome: ResolutionOutcome
    public var decision: DecisionCode
    public var tier: DispatchTier
    public var toolId: String?
    public var judge: JudgeRecord?
    public var feedback: DecisionFeedback?
    public var execution: DecisionExecution
    public var callDigest: String?
    public var proofDigest: String
    public var prevHash: String?
    public var hash: String

    /// The line as JSON (the `hash` included).
    public var jsonValue: AnyCodableValue {
        var body = bodyJSON
        body["hash"] = .string(hash)
        return .dict(body)
    }

    /// The line without `hash`: what the hash covers.
    var bodyJSON: [String: AnyCodableValue] {
        func optional(_ s: String?) -> AnyCodableValue { s.map { .string($0) } ?? .null }
        var object: [String: AnyCodableValue] = [
            "schema": .string(decisionLogSchema),
            "seq": .int(seq),
            "ts": .string(ts),
            "kind": .string(kind.rawValue),
            "intentDigest": optional(intentDigest),
            "principal": optional(principal),
            "artifactHash": optional(artifactHash),
            "embedderFingerprint": embedderFingerprint.map { .dict($0.jsonValue) } ?? .null,
            "outcome": .string(outcome.rawValue),
            "decision": .string(decision.rawValue),
            "tier": .string(tier.rawValue),
            "toolId": optional(toolId),
            "execution": .string(execution.rawValue),
            "callDigest": optional(callDigest),
            "proofDigest": .string(proofDigest),
            "prevHash": optional(prevHash),
        ]
        if let intent { object["intent"] = .string(intent) }
        if let judge { object["judge"] = judge.jsonValue }
        if let feedback {
            var f: [String: AnyCodableValue] = ["outcome": .string(feedback.outcome.rawValue), "correctToolId": optional(feedback.correctToolId)]
            if let reason = feedback.reason { f["reason"] = .string(reason) }
            object["feedback"] = .dict(f)
        }
        return object
    }
}

/// A decision log that is damaged, or a line that could not be written.
public struct DecisionLogError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// 1-based line number the problem was found at, when it is about one line
    public let line: Int?
    public init(_ message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }
    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

/// sha256hex(UTF8("smallchat.intent.v1") || 0x00 || UTF8(JCS(intent))).
public func intentDigest(_ intent: String) throws -> String {
    try domainDigest(intentDigestDomain, try canonicalJSON(.string(intent)))
}

/// The `hash` of a line: sha256hex of the JCS of the line without `hash`.
public func decisionRecordHash(_ body: [String: AnyCodableValue]) throws -> String {
    var withoutHash = body
    withoutHash["hash"] = nil
    return sha256Hex(Array(try canonicalJSON(.dict(withoutHash)).utf8))
}

/// ISO 8601 with milliseconds, as JavaScript's `toISOString` writes it.
func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// An append-only, hash-chained decision log: a file (created, with its
/// directory, if missing; mode 0600), or memory. Opening a file that
/// already has lines continues its chain after checking that the last
/// line is complete and intact.
public actor DecisionLog {
    /// The file, or nil for an in-memory log
    public nonisolated let path: String?
    private let recordIntent: Bool
    private let now: @Sendable () -> Date
    private var handle: FileHandle?
    private var seq = 0
    private var prevHash: String?
    private var memory: [String] = []

    /// `recordIntent`: record the intent text next to its digest (default true). Arguments are never recorded.
    public init(path: String? = nil, recordIntent: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.path = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.recordIntent = recordIntent
        self.now = now
        if let p = self.path {
            let opened = try Self.openFile(p)
            handle = opened.handle
            seq = opened.seq
            prevHash = opened.prevHash
        }
    }

    /// Sequence number and hash of the last line (seq 0 and nil when empty).
    public var head: (seq: Int, hash: String?) { (seq, prevHash) }

    /// The lines written by this instance of an in-memory log.
    public func lines() -> [String] { memory }

    /// Append one decision and return the line written. Throws DecisionLogError if it cannot be written.
    @discardableResult
    public func record(kind: DecisionKind, proof: ResolutionProof, execution: DecisionExecution, principal: String? = nil, toolId: String? = nil, feedback: DecisionFeedback? = nil) throws -> DecisionRecord {
        var record = DecisionRecord(
            seq: seq + 1,
            ts: isoTimestamp(now()),
            kind: kind,
            intent: recordIntent ? proof.intent : nil,
            intentDigest: try proof.intent.map { try intentDigest($0) },
            principal: principal,
            artifactHash: proof.artifactHash,
            embedderFingerprint: proof.embedder,
            outcome: proof.outcome,
            decision: proof.decision,
            tier: proof.tier,
            toolId: proof.chosen ?? toolId,
            judge: proof.judge,
            feedback: feedback,
            execution: execution,
            callDigest: execution == .ran ? proof.callDigest : nil,
            proofDigest: proof.proofDigest,
            prevHash: prevHash,
            hash: ""
        )
        record.hash = try decisionRecordHash(record.bodyJSON)
        let line = try canonicalJSONLine(record)
        if let handle {
            do {
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                throw DecisionLogError("Could not append to decision log \(path ?? ""): \(error)")
            }
        } else if path != nil {
            throw DecisionLogError("Decision log \(path ?? "") is closed")
        } else {
            memory.append(line)
        }
        seq = record.seq
        prevHash = record.hash
        return record
    }

    /// Close the file. Later record() calls throw.
    public func close() {
        try? handle?.close()
        handle = nil
    }

    private static func openFile(_ p: String) throws -> (handle: FileHandle, seq: Int, prevHash: String?) {
        var seq = 0
        var prevHash: String?
        let url = URL(fileURLWithPath: p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forUpdatingAtPath: p) else { throw DecisionLogError("Could not open decision log \(p)") }
        let data = (try? Data(contentsOf: url)) ?? Data()
        if !data.isEmpty {
            guard data.last == UInt8(ascii: "\n") else {
                try? h.close()
                throw DecisionLogError("Decision log \(p) ends with an incomplete line (an interrupted write?); move it aside or truncate it to its last complete line before appending.")
            }
            let text = String(decoding: data, as: UTF8.self)
            let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().last.map(String.init) ?? ""
            let record: DecisionRecord
            do {
                record = try parseDecisionRecord(lastLine, line: nil)
            } catch {
                try? h.close()
                throw DecisionLogError("Decision log \(p): its last line is not a decision record (\(error))")
            }
            guard try decisionRecordHash(record.bodyJSON) == record.hash else {
                try? h.close()
                throw DecisionLogError("Decision log \(p): the hash of its last line (seq \(record.seq)) does not match its content")
            }
            seq = record.seq
            prevHash = record.hash
        }
        try h.seekToEnd()
        return (h, seq, prevHash)
    }
}

/// A record's line: its JSON with sorted keys (any key order verifies; this is the one written).
func canonicalJSONLine(_ record: DecisionRecord) throws -> String {
    try canonicalJSON(record.jsonValue)
}

/// Whether a parsed JSON value looks like a decision-log line.
public func isDecisionRecord(_ value: AnyCodableValue) -> Bool {
    if case .dict(let object) = value { return object["schema"] == .string(decisionLogSchema) }
    return false
}

/// One line parsed and shape-checked (the hash is not checked here).
public func parseDecisionRecord(_ text: String, line: Int?) throws -> DecisionRecord {
    func fail(_ why: String) -> DecisionLogError { DecisionLogError(why, line: line) }
    guard let value = try? parseJSON(text), case .dict(let r) = value else { throw fail("not a JSON object") }
    guard r["schema"] == .string(decisionLogSchema) else { throw fail("schema is not \"\(decisionLogSchema)\"") }
    guard case .int(let seq)? = r["seq"], seq >= 1 else { throw fail("seq is not a positive integer") }
    guard case .string(let ts)? = r["ts"] else { throw fail("ts is not a string") }
    guard case .string(let kindRaw)? = r["kind"], let kind = DecisionKind(rawValue: kindRaw) else { throw fail("unknown kind \(r["kind"].map { "\($0)" } ?? "")") }
    guard case .string(let executionRaw)? = r["execution"], let execution = DecisionExecution(rawValue: executionRaw) else { throw fail("unknown execution") }
    func string(_ key: String) throws -> String {
        guard case .string(let s)? = r[key] else { throw fail("\(key) is not a string") }
        return s
    }
    func optional(_ key: String) throws -> String? {
        switch r[key] {
        case .null?, nil: return nil
        case .string(let s)?: return s
        default: throw fail("\(key) is not a string or null")
        }
    }
    var intent: String?
    if let i = r["intent"] {
        guard case .string(let s) = i else { throw fail("intent is not a string") }
        intent = s
    }
    guard let outcome = ResolutionOutcome(rawValue: try string("outcome")) else { throw fail("unknown outcome") }
    guard let decision = DecisionCode(rawValue: try string("decision")) else { throw fail("unknown decision") }
    guard let tier = DispatchTier(rawValue: try string("tier")) else { throw fail("unknown tier") }
    var judge: JudgeRecord?
    if let j = r["judge"] {
        guard let decoded = try? JSONDecoder().decode(JudgeRecord.self, from: JSONEncoder().encode(j)) else { throw fail("judge is not a judge record") }
        judge = decoded
    }
    var feedback: DecisionFeedback?
    if kind == .judgeFeedback {
        guard case .dict(let f)? = r["feedback"], case .string(let outcomeRaw)? = f["outcome"], let graded = JudgeGradeOutcome(rawValue: outcomeRaw) else {
            throw fail("a judge-feedback line needs a feedback grade")
        }
        var correct: String?
        switch f["correctToolId"] {
        case .null?, nil: correct = nil
        case .string(let s)?: correct = s
        default: throw fail("feedback.correctToolId is not a string or null")
        }
        var reason: String?
        if let rr = f["reason"] {
            guard case .string(let s) = rr else { throw fail("feedback.reason is not a string") }
            reason = s
        }
        guard judge != nil else { throw fail("a judge-feedback line names the judge it grades") }
        feedback = DecisionFeedback(outcome: graded, correctToolId: correct, reason: reason)
    } else if r["feedback"] != nil {
        throw fail("only a judge-feedback line carries feedback, not a \(kindRaw) line")
    }
    var fingerprint: EmbedderFingerprint?
    if let e = r["embedderFingerprint"], e != .null {
        guard let decoded = try? JSONDecoder().decode(EmbedderFingerprint.self, from: JSONEncoder().encode(e)) else { throw fail("embedderFingerprint is not a fingerprint") }
        fingerprint = decoded
    }
    return DecisionRecord(
        seq: seq, ts: ts, kind: kind, intent: intent, intentDigest: try optional("intentDigest"), principal: try optional("principal"),
        artifactHash: try optional("artifactHash"), embedderFingerprint: fingerprint, outcome: outcome, decision: decision, tier: tier,
        toolId: try optional("toolId"), judge: judge, feedback: feedback, execution: execution, callDigest: try optional("callDigest"),
        proofDigest: try string("proofDigest"), prevHash: try optional("prevHash"), hash: try string("hash")
    )
}

/// Result of verifyDecisionLog.
public struct DecisionLogVerification: Sendable {
    public var ok: Bool
    /// The records read, in order (up to the first problem when !ok)
    public var records: [DecisionRecord]
    /// Hash of the last verified line (nil for an empty log)
    public var head: String?
    /// The first problem found
    public var error: DecisionLogError?
}

/// Check a decision log's text line by line: every line is a decision
/// record, its hash matches its content, `seq` starts at 1 and increases by
/// one, and `prevHash` is the previous line's hash. Never throws.
public func verifyDecisionLog(_ text: String) -> DecisionLogVerification {
    var records: [DecisionRecord] = []
    var prev: DecisionRecord?
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    func fail(_ line: Int, _ message: String) -> DecisionLogVerification {
        DecisionLogVerification(ok: false, records: records, head: prev?.hash, error: DecisionLogError(message, line: line))
    }
    for (index, raw) in lines.enumerated() {
        let number = index + 1
        if raw.isEmpty {
            if index == lines.count - 1 { break }
            return fail(number, "empty line")
        }
        if index == lines.count - 1 { return fail(number, "incomplete last line (no trailing newline)") }
        let record: DecisionRecord
        do { record = try parseDecisionRecord(raw, line: number) } catch let e as DecisionLogError { return fail(number, e.message) } catch { return fail(number, "\(error)") }
        guard let expected = try? decisionRecordHash(record.bodyJSON), expected == record.hash else { return fail(number, "hash does not match the line's content") }
        guard record.seq == (prev?.seq ?? 0) + 1 else { return fail(number, "seq \(record.seq) does not follow seq \(prev?.seq ?? 0)") }
        guard record.prevHash == prev?.hash else { return fail(number, prev == nil ? "prevHash of seq 1 is not null" : "prevHash does not match the hash of seq \(prev!.seq)") }
        records.append(record)
        prev = record
    }
    return DecisionLogVerification(ok: true, records: records, head: prev?.hash, error: nil)
}

/// Read and verify a decision log file; throws DecisionLogError if it does not verify.
public func readDecisionLog(path: String) throws -> [DecisionRecord] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let result = verifyDecisionLog(text)
    guard result.ok else { throw result.error ?? DecisionLogError("decision log does not verify") }
    return result.records
}

// MARK: - Replay

/// What one logged decision looks like when replayed.
public struct DecisionReplayEntry: Sendable, Equatable {
    public enum Status: String, Sendable { case reproduced, differs, skipped }
    public struct Decided: Sendable, Equatable {
        public var outcome: ResolutionOutcome
        public var decision: DecisionCode
        public var tier: DispatchTier
        public var toolId: String?
        public var proofDigest: String?
    }
    public var seq: Int
    public var kind: DecisionKind
    public var intent: String?
    public var recorded: Decided
    public var replayed: Decided?
    public var status: Status
    public var reason: String?
    /// For `resolve` lines: whether the replayed proofDigest equals the logged one. Nil when not comparable.
    public var proofIdentical: Bool?
}

public struct DecisionReplayReport: Sendable {
    public var total: Int
    public var reproduced: Int
    public var differs: Int
    public var skipped: Int
    public var entries: [DecisionReplayEntry]
}

extension ToolRuntime {
    /// Re-decide every logged intent against this runtime (resolve only,
    /// learning off; nothing executes) and compare the outcome, tool id and
    /// tier with what was logged. A line's recorded judge verdict answers in
    /// the judge's place; no judge is ever called. Lines recorded against
    /// another artifact or embedder, digest-only lines, judge-feedback lines
    /// and decisions that rested on inputs the log does not hold are skipped
    /// with the reason.
    public func replayDecisionLog(_ records: [DecisionRecord]) async throws -> DecisionReplayReport {
        var entries: [DecisionReplayEntry] = []
        let artifactHash = await context.artifactHash
        let fingerprint = await context.embedder.fingerprint
        let hasVerifier = await context.llmClient.providesVerification
        func short(_ hash: String?) -> String { hash.map { "\($0.prefix(12))…" } ?? "(none)" }
        for record in records {
            let recorded = DecisionReplayEntry.Decided(outcome: record.outcome, decision: record.decision, tier: record.tier, toolId: record.toolId, proofDigest: record.proofDigest)
            var entry = DecisionReplayEntry(seq: record.seq, kind: record.kind, intent: record.intent, recorded: recorded, replayed: nil, status: .skipped, reason: nil, proofIdentical: nil)
            func skip(_ reason: String) { entry.status = .skipped; entry.reason = reason; entries.append(entry) }
            if record.artifactHash != artifactHash { skip("recorded against artifact \(short(record.artifactHash)), replaying \(short(artifactHash))"); continue }
            if record.kind != .dispatchById, record.embedderFingerprint != fingerprint { skip("recorded with a different embedder"); continue }
            if record.kind == .judgeFeedback { skip("a grade of the judged decision \(short(record.proofDigest)) (\(record.feedback?.outcome.rawValue ?? "graded")); nothing to replay"); continue }
            if record.kind == .dispatchById {
                var known = false
                if let id = record.toolId { known = await context.getTool(id) != nil }
                let outcome: ResolutionOutcome = known ? .resolved : .unresolved
                entry.replayed = .init(outcome: outcome, decision: known ? .exactId : .unknownTool, tier: known ? .exact : .none, toolId: record.toolId, proofDigest: nil)
                entry.status = outcome == record.outcome ? .reproduced : .differs
                if entry.status == .differs { entry.reason = "\(record.toolId ?? "") is \(known ? "now" : "no longer") a registered tool" }
                entries.append(entry)
                continue
            }
            guard let intent = record.intent, let digest = record.intentDigest else { skip("the log records only the intent digest (recordIntent: false)"); continue }
            if (try? intentDigest(intent)) != digest { entry.status = .differs; entry.reason = "intent text does not match intentDigest"; entries.append(entry); continue }
            if record.outcome == .throttled { skip("throttled by the rate limiter (depends on its window)"); continue }
            if record.decision == .decomposed { skip("decomposed by the LLM client (its answer is not recorded)"); continue }
            if record.decision == .llmVerified, !hasVerifier { skip("approved by an LLM verifier (its answer is not recorded)"); continue }
            if (record.decision == .judgeApproved || record.decision == .judgeDeclined), record.judge == nil { skip("decided by a shortlist judge whose verdict the line does not record"); continue }
            let override: JudgeOverride = record.judge.map { .recorded(RecordedJudgeVerdict($0)) } ?? .off
            let resolution = try await context.resolve(intent, options: ResolveOptions(learn: false, principal: record.principal, judge: override))
            let replayed = DecisionReplayEntry.Decided(outcome: resolution.outcome, decision: resolution.proof.decision, tier: resolution.tier, toolId: resolution.chosen, proofDigest: resolution.proof.proofDigest)
            var differences: [String] = []
            if replayed.outcome != record.outcome { differences.append("outcome \(record.outcome.rawValue) → \(replayed.outcome.rawValue)") }
            if replayed.toolId != record.toolId { differences.append("tool \(record.toolId ?? "none") → \(replayed.toolId ?? "none")") }
            if replayed.tier != record.tier { differences.append("tier \(record.tier.rawValue) → \(replayed.tier.rawValue)") }
            entry.replayed = replayed
            entry.status = differences.isEmpty ? .reproduced : .differs
            entry.reason = differences.isEmpty ? nil : "\(differences.joined(separator: ", ")) (logged decision: \(record.decision.rawValue))"
            entry.proofIdentical = record.kind == .resolve ? replayed.proofDigest == record.proofDigest : nil
            entries.append(entry)
        }
        return DecisionReplayReport(
            total: entries.count,
            reproduced: entries.filter { $0.status == .reproduced }.count,
            differs: entries.filter { $0.status == .differs }.count,
            skipped: entries.filter { $0.status == .skipped }.count,
            entries: entries
        )
    }
}
