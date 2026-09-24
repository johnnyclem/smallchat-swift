import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Notary client
//
// Stenographer's notary routes (REST, loopback):
//
//   GET  /proposals?status=open&kind=tombstone      the review inbox
//   POST /proposals/:id/notarize {notary}           mint the TB
//   POST /proposals/:id/dismiss  {dismissedBy, reason}
//
// The POSTs need `X-Notary-Secret` (stenographer's STENOGRAPHER_NOTARY_SECRET).
// The messenger uses its channel secret for both, and never hands it to agents.

public enum NotaryDecision: Sendable, Equatable {
    case approve(notary: String)
    case decline(by: String, reason: String)
}

public enum NotaryError: Error, Equatable, CustomStringConvertible {
    case rejected(status: Int, message: String)
    case badResponse

    public var description: String {
        switch self {
        case .rejected(let status, let message): return "stenographer refused (\(status)): \(message)"
        case .badResponse: return "stenographer sent a response the messenger couldn't read"
        }
    }
}

public enum NotaryClient {
    public static let secretHeader = "X-Notary-Secret"

    /// The request for a decision. `notarizeURL` is `…/proposals/:id/notarize`;
    /// declining posts to its sibling `…/dismiss`.
    public static func request(for decision: NotaryDecision, notarizeURL: URL, secret: String) throws -> URLRequest {
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

    /// `restBase/proposals/:id/notarize`.
    public static func notarizeURL(restBase: URL, proposalId: String) -> URL {
        restBase.appendingPathComponent("proposals").appendingPathComponent(proposalId).appendingPathComponent("notarize")
    }

    /// Open agent drafts in stenographer's inbox, for when the push was missed.
    public static func openDrafts(restBase: URL, session: URLSession = .shared) async throws -> [PendingProposal] {
        var components = URLComponents(url: restBase.appendingPathComponent("proposals"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "status", value: "open"), URLQueryItem(name: "kind", value: "tombstone")]
        guard let url = components?.url else { throw NotaryError.badResponse }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 5))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NotaryError.rejected(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return try parseInbox(data, restBase: restBase)
    }

    /// The agent drafts in a `GET /proposals` response (other proposals are
    /// detector output the user signs elsewhere).
    public static func parseInbox(_ data: Data, restBase: URL) throws -> [PendingProposal] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NotaryError.badResponse
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String,
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
                content: "\(author) drafted a tombstone for your approval (\(id)): \(claim)" + (why.map { "\nWhy: \($0)" } ?? ""),
                notarizeURL: notarizeURL(restBase: restBase, proposalId: id)
            )
        }
    }
}
