import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SmallChatCore
import SmallChatTruth

// MARK: - Notary client
//
// Stenographer's notary routes (REST, loopback):
//
//   GET  /proposals?status=open&kind=tombstone      the review inbox
//   POST /proposals                 {PROPOSAL envelope}    file a draft (201/200 {proposalId})
//   POST /proposals/:id/notarize    {notary}               mint the TB
//   POST /proposals/:id/dismiss     {dismissedBy, reason}
//
// The POSTs need `X-Notary-Secret` (stenographer's STENOGRAPHER_NOTARY_SECRET),
// and every route `Authorization: Bearer` (STENOGRAPHER_REST_TOKEN) unless
// stenographer runs with --rest-insecure. The messenger keeps a notary
// secret of its own, separate from the channel secret stenographer posts
// objections with, and never hands it to agents. The URL is always built
// from the configured REST port, never taken from a channel event, so a
// forged event can't collect the secret.
//
// One writer per wiki file: a tombstone the user signs in the messenger is
// filed as a PROPOSAL envelope and notarized by them — stenographer writes
// the TB, and exports it. The messenger never appends to a wiki file.

public enum NotaryDecision: Sendable, Equatable {
    case approve(notary: String)
    case decline(by: String, reason: String)
}

public enum NotaryError: Error, Equatable, CustomStringConvertible {
    case rejected(status: Int, message: String)
    case badResponse
    /// Stenographer holds a different envelope under this id (409).
    case conflict(proposalId: String?, message: String)

    public var description: String {
        switch self {
        case .rejected(let status, let message): return "stenographer refused (\(status)): \(message)"
        case .badResponse: return "stenographer sent a response the messenger couldn't read"
        case .conflict(_, let message): return "stenographer already holds a different proposal under this id: \(message)"
        }
    }
}

/// A tombstone stenographer minted from a notarized proposal.
public struct NotarizedTombstone: Sendable, Equatable {
    /// The proposal the envelope was filed as.
    public let proposalId: String
    /// The minted entry's id, when stenographer said.
    public let entryId: String?
    /// The minted TB as stenographer returned it, when it could be read.
    public let tombstone: TruthTbEntry?
}

public enum NotaryClient {
    public static let secretHeader = "X-Notary-Secret"

    /// Adds `Authorization: Bearer <token>` when there is a token.
    static func authorize(_ request: inout URLRequest, restToken: String?) {
        guard let restToken, !restToken.isEmpty else { return }
        request.setValue("Bearer \(restToken)", forHTTPHeaderField: "Authorization")
    }

    /// The request for a decision. `notarizeURL` is `…/proposals/:id/notarize`;
    /// declining posts to its sibling `…/dismiss`.
    public static func request(for decision: NotaryDecision, notarizeURL: URL, secret: String, restToken: String? = nil) throws -> URLRequest {
        var url = notarizeURL
        let body: [String: String]
        switch decision {
        case .approve(let notary):
            body = ["notary": notary]
        case .decline(let by, let reason):
            url = notarizeURL.deletingLastPathComponent().appendingPathComponent("dismiss")
            body = ["dismissedBy": by, "reason": reason]
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: secretHeader)
        authorize(&request, restToken: restToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Sends a decision. Returns the id of the entry stenographer wrote (the
    /// minted TB on approve, the dismissed proposal on decline).
    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> String? {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw NotaryError.rejected(
                status: status,
                message: json?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return json?["id"] as? String
    }

    // MARK: Submitting a proposal

    /// `POST restBase/proposals` with one PROPOSAL envelope, as a stream of
    /// its own (seq 1, prevHash null, hash), so stenographer checks its hash.
    public static func submissionRequest(_ envelope: TruthProposalEnvelope, restBase: URL, secret: String, restToken: String?) throws -> URLRequest {
        var request = URLRequest(url: restBase.appendingPathComponent("proposals"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: secretHeader)
        authorize(&request, restToken: restToken)
        request.httpBody = Data(try envelope.line().utf8)
        return request
    }

    /// Reads a `POST /proposals` response: `201 {proposalId}` when filed,
    /// `200 {proposalId}` when this envelope was filed before (stenographer
    /// files an envelope once, by its id). Returns the proposal id.
    public static func proposalId(status: Int, data: Data) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 409 {
            throw NotaryError.conflict(proposalId: json?["proposalId"] as? String, message: json?["error"] as? String ?? "conflict")
        }
        guard status == 200 || status == 201 else {
            throw NotaryError.rejected(status: status, message: json?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        guard let id = json?["proposalId"] as? String, isValidProposalId(id) else { throw NotaryError.badResponse }
        return id
    }

    /// Files `envelope` with stenographer, then notarizes it as `notary`,
    /// which mints the TB under their name. Retrying with the same envelope
    /// is safe: stenographer answers a re-submitted envelope with the
    /// proposal it already filed.
    public static func submitAndNotarize(
        _ envelope: TruthProposalEnvelope,
        notary: String,
        restBase: URL,
        secret: String,
        restToken: String?,
        session: URLSession = .shared
    ) async throws -> NotarizedTombstone {
        let submission = try submissionRequest(envelope, restBase: restBase, secret: secret, restToken: restToken)
        let (submitted, submitResponse) = try await session.data(for: submission)
        let proposalId = try proposalId(status: (submitResponse as? HTTPURLResponse)?.statusCode ?? 0, data: submitted)

        guard let url = notarizeURL(restBase: restBase, proposalId: proposalId) else { throw NotaryError.badResponse }
        let notarize = try request(for: .approve(notary: notary), notarizeURL: url, secret: secret, restToken: restToken)
        let (minted, response) = try await session.data(for: notarize)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: minted)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw NotaryError.rejected(status: status, message: json?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return NotarizedTombstone(proposalId: proposalId, entryId: json?["id"] as? String, tombstone: tombstone(fromEntry: minted))
    }

    /// The TB in a notarize response (stenographer's entry:
    /// `{id, type: "TB", author, createdAt, body: {claim, evidence, signedBy, status, literals?}}`),
    /// or nil when it isn't one.
    public static func tombstone(fromEntry data: Data) -> TruthTbEntry? {
        guard case .dict(let entry)? = try? parseJSON(data),
              entry["type"] == .string("TB"),
              case .string(let id)? = entry["id"], case .string(let author)? = entry["author"],
              case .dict(let body)? = entry["body"], case .string(let claim)? = body["claim"]
        else { return nil }
        func string(_ value: AnyCodableValue?) -> String? {
            if case .string(let s)? = value { return s }
            return nil
        }
        var evidence: [TruthEvidence] = []
        if case .array(let items)? = body["evidence"] {
            for case .dict(let e) in items {
                evidence.append(TruthEvidence(kind: TruthEvidence.Kind(rawValue: string(e["kind"]) ?? ""), ref: string(e["ref"]) ?? "", detail: string(e["detail"])))
            }
        }
        var literals: [TruthTombstonedLiteral] = []
        if case .array(let items)? = body["literals"] {
            for case .dict(let l) in items {
                guard let dead = string(l["dead"]) else { continue }
                literals.append(TruthTombstonedLiteral(dead: dead, subject: string(l["subject"]), current: string(l["current"])))
            }
        }
        return TruthTbEntry(
            id: id,
            ts: string(entry["createdAt"]) ?? "",
            author: author,
            claim: claim,
            evidence: evidence,
            signedBy: string(body["signedBy"]),
            status: string(body["status"]).map(TbStatus.init(rawValue:)),
            literals: literals
        )
    }

    // MARK: URLs and the inbox

    /// `restBase/proposals/:id/notarize`, or nil when `proposalId` isn't a
    /// plain id (see `isValidProposalId`).
    public static func notarizeURL(restBase: URL, proposalId: String) -> URL? {
        guard isValidProposalId(proposalId) else { return nil }
        return restBase.appendingPathComponent("proposals").appendingPathComponent(proposalId).appendingPathComponent("notarize")
    }

    /// Stenographer's ids are ULIDs. Anything beyond letters, digits, `-`
    /// and `_` (a `/`, `..`, `?`) could steer a request elsewhere.
    public static func isValidProposalId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// Open agent drafts in stenographer's inbox, for when the push was missed.
    public static func openDrafts(restBase: URL, restToken: String? = nil, session: URLSession = .shared) async throws -> [PendingProposal] {
        var components = URLComponents(url: restBase.appendingPathComponent("proposals"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "status", value: "open"), URLQueryItem(name: "kind", value: "tombstone")]
        guard let url = components?.url else { throw NotaryError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 5)
        authorize(&request, restToken: restToken)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NotaryError.rejected(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return try parseInbox(data)
    }

    /// The agent drafts in a `GET /proposals` response (other proposals are
    /// detector output the user signs elsewhere).
    public static func parseInbox(_ data: Data) throws -> [PendingProposal] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NotaryError.badResponse
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, isValidProposalId(id),
                  let body = entry["body"] as? [String: Any],
                  body["requiresNotary"] as? Bool == true,
                  body["status"] as? String == "open"
            else { return nil }
            let draft = body["draft"] as? [String: Any]
            let author = entry["author"] as? String ?? "an agent"
            let why = (body["signal"] as? [String: Any])?["detail"] as? String
            let claim = draft?["claim"] as? String ?? ""
            return PendingProposal(
                id: id,
                draftedBy: author,
                sessionIds: (entry["agentSessionId"] as? String).map { [$0] } ?? [],
                content: "\(author) drafted a tombstone for your approval (\(id)): \(claim)" + (why.map { "\nWhy: \($0)" } ?? "")
            )
        }
    }
}
