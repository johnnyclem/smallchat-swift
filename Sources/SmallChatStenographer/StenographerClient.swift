import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SmallChatCore
@_exported import SmallChatTruth

// MARK: - SmallChatStenographer
//
// A Swift client for Stenographer (github.com/johnnyclem/stenographer),
// the MCP court reporter: an adapter over the TypeScript server's REST API
// (daemon mode, or `--rest-port`), with the truth-format v2 reader
// (SmallChatTruth) re-exported. Nothing here reimplements the ledger: a
// Swift app launches or attaches to the TypeScript stenographer
// (StenographerProcess), reads its index and ledger through this client,
// submits proposals for a person to notarize, and gives the dispatch
// runtime's judge the session's tombstones and transcript
// (StenographerJudgeContext).
//
// Every request carries `Authorization: Bearer <token>` (stenographer's
// `rest-token` file, or STENOGRAPHER_REST_TOKEN) unless the server runs
// with --rest-insecure; the notary routes also take `X-Notary-Secret`.
// The base URL must be loopback unless `allowRemote`, since transcripts
// travel back.

/// An HTTP exchange: a request in, the body and status out. Injectable for tests.
public typealias StenographerTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public struct StenographerClientError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The server answered with this status (its `error` field, when it sent one, is in `message`)
        case status(Int)
        /// The server could not be reached, or stopped answering
        case network
        /// The answer was not what the route promises
        case badResponse
        /// An option out of range
        case invalid
    }
    public let kind: Kind
    public let message: String
    public var description: String { message }
}

/// What `GET /status` reports (the fields a client reads; the rest is in `raw`).
public struct StenographerStatus: Sendable, Equatable {
    public var messagesIndexed: Int
    public var entities: Int
    public var decisions: Int
    public var tombstones: Int
    public var sessionId: String?
    public var mode: String?
    public var version: String?
    public var raw: AnyCodableValue
}

/// A conversation message as `GET /messages` returns it.
public struct StenographerMessage: Sendable, Equatable {
    public var id: String
    public var role: String
    public var content: String
    public var timestamp: String
    public var sessionId: String?
}

/// A truth entry as the REST API returns it (TB or UV; the ledger's record shape, not a wiki line).
public struct StenographerTruthEntry: Sendable, Equatable {
    public struct Literal: Sendable, Equatable {
        public var subject: String?
        public var dead: String
        public var current: String?
    }
    public var id: String
    /// `TB` or `UV`
    public var type: String
    public var author: String
    public var status: String
    /// A TB's claim or a UV's assertion
    public var text: String
    public var evidenceKinds: [String]
    public var literals: [Literal]
    /// `sound`, `clouded` or `unsupported`, when the server reports it
    public var standing: String?
    public var raw: AnyCodableValue

    /// The grade the smallchat handoff gives an entry a judge is offered, or nil for one that is dead.
    public var grade: String? {
        if type == "UV" { return status == "open" ? "advisory" : nil }
        guard type == "TB", status == "active" || status == "contested", standing != "unsupported" else { return nil }
        if evidenceKinds.contains(where: { $0 == "command" || $0 == "test" }) { return "verified" }
        return author == "migration" ? "migration" : "asserted"
    }
}

/// The decision model's verdict on an objection or a consult (`GET /advice`).
public struct StenographerAdvice: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var subjectId: String
    public var adviser: String
    public var model: String
    public var reasserts: Double?
    public var contradicts: Double?
    public var cites: String?
    public var grade: String?
    public var truth: String?
    public var error: String?
}

/// A real-time objection as `GET /flags` returns it.
public struct StenographerObjection: Sendable, Equatable {
    public var id: String
    public var sessionId: String
    public var messageId: String
    public var tbId: String
    public var objection: String
    public var transcriptLine: String
    public var status: String
    public var delivered: Bool
    public var advice: StenographerAdvice?
    public var raw: AnyCodableValue
}

/// What `POST /advice/consult` answers.
public struct StenographerConsult: Sendable, Equatable {
    public var adviser: String
    public var model: String
    public var contradicts: Double?
    public var cites: String?
    public var entryIds: [String]
    public var error: String?
}

/// How the decision model has done against the judge (`GET /advice/stats`).
public struct StenographerAdviceStats: Sendable, Equatable {
    public var adviser: String
    public var model: String
    public var objections: Int
    public var consults: Int
    public var graded: Int
    public var rewarded: Int
    public var corrected: Int
    public var accuracy: Double?
    public var errors: Int
}

private let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

public struct StenographerClient: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    private let token: String?
    private let notarySecret: String?
    private let transport: StenographerTransport

    /// `token`: the REST bearer token. `notarySecret`: for the notary routes
    /// (never give it to agents). Loopback only unless `allowRemote`.
    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8787")!,
        token: String? = nil,
        notarySecret: String? = nil,
        timeout: TimeInterval = 5,
        allowRemote: Bool = false,
        transport: StenographerTransport? = nil
    ) throws {
        guard let host = baseURL.host, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil else {
            throw StenographerClientError(kind: .invalid, message: "StenographerClient: baseURL must name a host and carry no credentials or query")
        }
        guard baseURL.scheme == "http" || baseURL.scheme == "https" else {
            throw StenographerClientError(kind: .invalid, message: "StenographerClient: baseURL must be http or https")
        }
        if !loopbackHosts.contains(host), !allowRemote {
            throw StenographerClientError(kind: .invalid, message: "StenographerClient: baseURL must be a loopback host unless allowRemote is set (transcripts travel back)")
        }
        if let token, token.isEmpty || !token.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) {
            throw StenographerClientError(kind: .invalid, message: "StenographerClient: the token is a plain ASCII string")
        }
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = URL(string: trimmed) ?? baseURL
        self.token = token
        self.notarySecret = notarySecret
        self.timeout = timeout
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    /// Whether requests carry a bearer token.
    public var authenticated: Bool { token != nil }

    // MARK: Requests

    func url(_ path: String, query: [(String, String?)] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    func request(_ method: String, _ path: String, query: [(String, String?)] = [], body: AnyCodableValue? = nil, notary: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if notary {
            guard let notarySecret else { throw StenographerClientError(kind: .invalid, message: "this route needs the notary secret (STENOGRAPHER_NOTARY_SECRET)") }
            request.setValue(notarySecret, forHTTPHeaderField: "X-Notary-Secret")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(try canonicalJSON(body).utf8)
        }
        return request
    }

    /// Send a request and parse the JSON answer; a non-2xx status is an error naming it.
    public func send(_ request: URLRequest) async throws -> AnyCodableValue {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw StenographerClientError(kind: .network, message: "stenographer at \(baseURL.absoluteString) did not answer: \(error)")
        }
        let parsed = try? parseJSON(data)
        guard (200..<300).contains(response.statusCode) else {
            var message = "stenographer answered \(response.statusCode)"
            if case .dict(let object)? = parsed, case .string(let error)? = object["error"] { message += ": \(error)" }
            throw StenographerClientError(kind: .status(response.statusCode), message: message)
        }
        guard let parsed else { throw StenographerClientError(kind: .badResponse, message: "stenographer answered with something other than JSON") }
        return parsed
    }

    public func get(_ path: String, query: [(String, String?)] = []) async throws -> AnyCodableValue {
        try await send(try request("GET", path, query: query))
    }

    // MARK: Index

    public func status() async throws -> StenographerStatus {
        let raw = try await get("/status")
        return StenographerStatus(
            messagesIndexed: raw["messagesIndexed"]?.intValue ?? 0,
            entities: raw["entities"]?.intValue ?? 0,
            decisions: raw["decisions"]?.intValue ?? 0,
            tombstones: raw["tombstones"]?.intValue ?? 0,
            sessionId: raw["sessionId"]?.stringValue,
            mode: raw["mode"]?.stringValue,
            version: raw["version"]?.stringValue,
            raw: raw
        )
    }

    /// The newest `n` messages, newest first (as the server returns them).
    public func recentMessages(n: Int = 10) async throws -> [StenographerMessage] {
        try await get("/messages", query: [("n", String(max(1, n)))]).arrayValue.compactMap(Self.message)
    }

    /// GraphRAG search over the index.
    public func search(_ query: String, k: Int = 5, depth: Int = 2) async throws -> AnyCodableValue {
        try await get("/graphrag", query: [("q", query), ("k", String(k)), ("depth", String(depth))])
    }

    /// The markdown context frame within a token budget.
    public func contextFrame(budget: Int = 2000) async throws -> String {
        let (data, response) = try await transport(try request("GET", "/context-frame", query: [("budget", String(budget))]))
        guard (200..<300).contains(response.statusCode) else { throw StenographerClientError(kind: .status(response.statusCode), message: "stenographer answered \(response.statusCode)") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Truth

    /// Truth entries by filter (`current` by default), as `get_truth`.
    public func truth(filter: String = "current") async throws -> [StenographerTruthEntry] {
        try await get("/truth", query: [("filter", filter)]).arrayValue.compactMap(Self.truthEntry)
    }

    /// Truth entries ranked by relevance to `query`, as `search_truth`.
    public func searchTruth(_ query: String, k: Int = 5, filter: String = "current") async throws -> [StenographerTruthEntry] {
        try await get("/truth/search", query: [("q", query), ("k", String(k)), ("filter", filter)]).arrayValue.compactMap(Self.truthEntry)
    }

    public func docket() async throws -> AnyCodableValue { try await get("/docket") }

    public func precedents(scope: String? = nil, all: Bool = false) async throws -> AnyCodableValue {
        try await get("/precedents", query: [("scope", scope), ("all", all ? "true" : nil)])
    }

    public func derivation(of id: String, direction: String = "down") async throws -> AnyCodableValue {
        guard Self.isPlainId(id) else { throw StenographerClientError(kind: .invalid, message: "not a plain entry id") }
        return try await get("/truth/\(id)/derivation", query: [("direction", direction)])
    }

    // MARK: Objections and the decision model

    /// Real-time objections (`GET /flags`); `since` is an exclusive id cursor.
    public func objections(since: String? = nil, status: String? = nil, includeShadow: Bool = false) async throws -> [StenographerObjection] {
        try await get("/flags", query: [("since", since), ("status", status), ("include", includeShadow ? "shadow" : nil)]).arrayValue.compactMap(Self.objection)
    }

    /// The decision model's verdicts (`GET /advice`).
    public func advice(kind: String? = nil, graded: Bool? = nil, since: String? = nil, limit: Int = 100) async throws -> [StenographerAdvice] {
        try await get("/advice", query: [("kind", kind), ("graded", graded.map { $0 ? "true" : "false" }), ("since", since), ("limit", String(limit))])
            .arrayValue.compactMap(Self.advice)
    }

    /// How the decision model does against the judge; nil when none is configured (404).
    public func adviceStats() async throws -> StenographerAdviceStats? {
        do {
            let raw = try await get("/advice/stats")
            return StenographerAdviceStats(
                adviser: raw["adviser"]?.stringValue ?? "", model: raw["model"]?.stringValue ?? "",
                objections: raw["objections"]?.intValue ?? 0, consults: raw["consults"]?.intValue ?? 0, graded: raw["graded"]?.intValue ?? 0,
                rewarded: raw["rewarded"]?.intValue ?? 0, corrected: raw["corrected"]?.intValue ?? 0, accuracy: raw["accuracy"]?.doubleValue,
                errors: raw["errors"]?.intValue ?? 0
            )
        } catch let error as StenographerClientError where error.kind == .status(404) {
            return nil
        }
    }

    /// Ask the decision model whether an assertion contradicts the ledger (`POST /advice/consult`).
    public func consult(_ assertion: String, k: Int? = nil) async throws -> StenographerConsult {
        var body: [String: AnyCodableValue] = ["assertion": .string(assertion)]
        if let k { body["k"] = .int(k) }
        let raw = try await send(try request("POST", "/advice/consult", body: .dict(body)))
        return StenographerConsult(
            adviser: raw["adviser"]?.stringValue ?? "", model: raw["model"]?.stringValue ?? "",
            contradicts: raw["contradicts"]?.doubleValue, cites: raw["cites"]?.stringValue,
            entryIds: raw["entries"]?.arrayValue.compactMap { $0["id"]?.stringValue } ?? [], error: raw["error"]?.stringValue
        )
    }

    // MARK: Proposals and the notary (X-Notary-Secret)

    /// The review inbox (`GET /proposals`).
    public func proposals(status: String? = "open", kind: String? = nil) async throws -> AnyCodableValue {
        try await get("/proposals", query: [("status", status), ("kind", kind)])
    }

    /// File one truth format v2 PROPOSAL envelope (`POST /proposals`); the proposal id.
    public func submitProposal(_ envelope: AnyCodableValue) async throws -> String {
        let raw = try await send(try request("POST", "/proposals", body: envelope, notary: true))
        guard let id = raw["proposalId"]?.stringValue else { throw StenographerClientError(kind: .badResponse, message: "no proposalId in the answer") }
        return id
    }

    /// Notarize a proposal in a person's name (`POST /proposals/:id/notarize`): the minted entry.
    public func notarize(_ proposalId: String, notary: String, edits: AnyCodableValue? = nil) async throws -> AnyCodableValue {
        guard Self.isPlainId(proposalId) else { throw StenographerClientError(kind: .invalid, message: "not a plain proposal id") }
        var body: [String: AnyCodableValue] = ["notary": .string(notary)]
        if let edits { body["edits"] = edits }
        return try await send(try request("POST", "/proposals/\(proposalId)/notarize", body: .dict(body), notary: true))
    }

    /// Dismiss a proposal with a reason (`POST /proposals/:id/dismiss`).
    public func dismiss(_ proposalId: String, by: String, reason: String) async throws -> AnyCodableValue {
        guard Self.isPlainId(proposalId) else { throw StenographerClientError(kind: .invalid, message: "not a plain proposal id") }
        return try await send(try request("POST", "/proposals/\(proposalId)/dismiss", body: .dict(["dismissedBy": .string(by), "reason": .string(reason)]), notary: true))
    }

    // MARK: Parsing

    /// Stenographer's ids are ULIDs; anything beyond letters, digits, `-` and `_` could steer a request elsewhere.
    public static func isPlainId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x5F }
    }

    static func message(_ v: AnyCodableValue) -> StenographerMessage? {
        guard let id = v["id"]?.stringValue, let role = v["role"]?.stringValue, let content = v["content"]?.stringValue else { return nil }
        return StenographerMessage(id: id, role: role, content: content, timestamp: v["timestamp"]?.stringValue ?? "", sessionId: v["sessionId"]?.stringValue)
    }

    static func truthEntry(_ v: AnyCodableValue) -> StenographerTruthEntry? {
        guard let id = v["id"]?.stringValue, let type = v["type"]?.stringValue, type == "TB" || type == "UV", let body = v["body"] else { return nil }
        let text = (type == "TB" ? body["claim"] : body["assertion"])?.stringValue ?? ""
        let literals = body["literals"]?.arrayValue.compactMap { l -> StenographerTruthEntry.Literal? in
            guard let dead = l["dead"]?.stringValue else { return nil }
            return .init(subject: l["subject"]?.stringValue, dead: dead, current: l["current"]?.stringValue)
        } ?? []
        return StenographerTruthEntry(
            id: id, type: type, author: v["author"]?.stringValue ?? "", status: body["status"]?.stringValue ?? "", text: text,
            evidenceKinds: body["evidence"]?.arrayValue.compactMap { $0["kind"]?.stringValue } ?? [], literals: literals,
            standing: v["standing"]?.stringValue, raw: v
        )
    }

    static func advice(_ v: AnyCodableValue) -> StenographerAdvice? {
        guard let id = v["id"]?.stringValue, let kind = v["kind"]?.stringValue else { return nil }
        return StenographerAdvice(
            id: id, kind: kind, subjectId: v["subjectId"]?.stringValue ?? "", adviser: v["adviser"]?.stringValue ?? "", model: v["model"]?.stringValue ?? "",
            reasserts: v["reasserts"]?.doubleValue, contradicts: v["contradicts"]?.doubleValue, cites: v["cites"]?.stringValue,
            grade: v["grade"]?.stringValue, truth: v["truth"]?.stringValue, error: v["error"]?.stringValue
        )
    }

    static func objection(_ v: AnyCodableValue) -> StenographerObjection? {
        guard let id = v["id"]?.stringValue, let tbId = v["tbId"]?.stringValue else { return nil }
        return StenographerObjection(
            id: id, sessionId: v["sessionId"]?.stringValue ?? "", messageId: v["messageId"]?.stringValue ?? "", tbId: tbId,
            objection: v["objection"]?.stringValue ?? "", transcriptLine: v["transcriptLine"]?.stringValue ?? "",
            status: v["status"]?.stringValue ?? "pending", delivered: v["delivered"]?.boolValue ?? false,
            advice: v["advice"].flatMap(advice), raw: v
        )
    }
}

extension AnyCodableValue {
    subscript(key: String) -> AnyCodableValue? {
        if case .dict(let object) = self { return object[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var arrayValue: [AnyCodableValue] {
        if case .array(let items) = self { return items }
        return []
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
