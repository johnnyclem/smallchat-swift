import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SmallChatCore
import SmallChatRuntime
@testable import SmallChatStenographer

/// A fake stenographer: routes answered by path, requests recorded.
final class FakeStenographer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var routes: [String: (Int, String)] = [:]

    init(_ routes: [String: (Int, String)] = [:]) { self.routes = routes }

    private func record(_ request: URLRequest) {
        lock.lock(); requests.append(request); lock.unlock()
    }

    var transport: StenographerTransport {
        { [self] request in
            record(request)
            let path = request.url!.path
            let (status, body) = routes[path] ?? (404, #"{"error":"no such route"}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func client(token: String? = nil, notarySecret: String? = nil) throws -> StenographerClient {
        try StenographerClient(baseURL: URL(string: "http://127.0.0.1:8787/")!, token: token, notarySecret: notarySecret, transport: transport)
    }

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests.map { $0.url!.path } }
}

private let truthBody = """
[
 {"id":"tb_1","type":"TB","author":"alice","standing":"supported","body":{"status":"active","claim":"The API lives on port 8787","evidence":[{"kind":"command"}],"literals":[{"subject":"port","dead":"8080","current":"8787"}]}},
 {"id":"tb_2","type":"TB","author":"migration","body":{"status":"active","claim":"Migrated from v1"}},
 {"id":"tb_3","type":"TB","author":"bob","body":{"status":"active","claim":"Bob says so"}},
 {"id":"tb_4","type":"TB","author":"bob","standing":"unsupported","body":{"status":"active","claim":"Unsupported"}},
 {"id":"tb_5","type":"TB","author":"bob","body":{"status":"retired","claim":"Retired"}},
 {"id":"uv_1","type":"UV","author":"carol","body":{"status":"open","assertion":"Maybe the port moved again"}},
 {"id":"uv_2","type":"UV","author":"carol","body":{"status":"resolved","assertion":"Settled"}},
 {"id":"x","type":"TX"}
]
"""

private let messagesBody = """
[
 {"id":"m3","role":"assistant","content":"Sending it now","timestamp":"2026-01-01T00:00:03Z","sessionId":"s1"},
 {"id":"m2","role":"user","content":"   ","timestamp":"2026-01-01T00:00:02Z"},
 {"id":"m1","role":"user","content":"Send the report to Bob","timestamp":"2026-01-01T00:00:01Z"},
 {"id":"m0","role":"narrator","content":"not a judge role","timestamp":"2026-01-01T00:00:00Z"}
]
"""

struct StenographerClientTests {
    @Test("the client refuses remote hosts, credentials in the URL and non-ASCII tokens; trims trailing slashes")
    func construction() throws {
        let client = try StenographerClient(baseURL: URL(string: "http://localhost:8787///")!)
        #expect(client.baseURL.absoluteString == "http://localhost:8787")
        #expect(!client.authenticated)
        #expect(throws: StenographerClientError.self) { try StenographerClient(baseURL: URL(string: "http://steno.example.com:8787")!) }
        _ = try StenographerClient(baseURL: URL(string: "http://steno.example.com:8787")!, allowRemote: true)
        #expect(throws: StenographerClientError.self) { try StenographerClient(baseURL: URL(string: "http://u:p@127.0.0.1:8787")!) }
        #expect(throws: StenographerClientError.self) { try StenographerClient(baseURL: URL(string: "ftp://127.0.0.1:8787")!) }
        #expect(throws: StenographerClientError.self) { try StenographerClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "") }
        #expect(throws: StenographerClientError.self) { try StenographerClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "tök") }
        #expect(try StenographerClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "abc").authenticated)
    }

    @Test("status and messages are read with the bearer token; non-2xx answers become status errors naming the server's message")
    func statusAndErrors() async throws {
        let fake = FakeStenographer([
            "/status": (200, #"{"messagesIndexed":12,"entities":3,"decisions":1,"tombstones":2,"sessionId":"s1","mode":"daemon","version":"1.1.0"}"#),
            "/messages": (200, messagesBody),
            "/flags": (401, #"{"error":"unauthorized"}"#),
        ])
        let client = try fake.client(token: "secret")
        let status = try await client.status()
        #expect(status.messagesIndexed == 12 && status.tombstones == 2 && status.sessionId == "s1" && status.version == "1.1.0")
        let messages = try await client.recentMessages(n: 3)
        #expect(messages.map(\.id) == ["m3", "m2", "m1", "m0"])
        #expect(messages[0].sessionId == "s1")
        await #expect(throws: StenographerClientError.self) { try await client.objections() }
        do { _ = try await client.objections() } catch let error as StenographerClientError {
            #expect(error.kind == .status(401))
            #expect(error.message.contains("unauthorized"))
        }
        let sent = fake.requests
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        #expect(sent[1].url?.query == "n=3")
    }

    @Test("truth entries carry the smallchat grade: verified, migration, asserted, advisory, or none when dead")
    func truthGrades() async throws {
        let fake = FakeStenographer(["/truth": (200, truthBody)])
        let entries = try await fake.client().truth()
        #expect(entries.map(\.id) == ["tb_1", "tb_2", "tb_3", "tb_4", "tb_5", "uv_1", "uv_2"])
        #expect(entries.map(\.grade) == ["verified", "migration", "asserted", nil, nil, "advisory", nil])
        #expect(entries[0].text == "The API lives on port 8787")
        #expect(entries[0].literals == [.init(subject: "port", dead: "8080", current: "8787")])
        #expect(entries[5].text == "Maybe the port moved again")
        #expect(fake.requests[0].url?.query == "filter=current")
    }

    @Test("the judge context grades what the ledger search returns, reads the transcript oldest first, and skips blank or unknown lines")
    func judgeContext() async throws {
        let fake = FakeStenographer(["/truth/search": (200, truthBody), "/messages": (200, messagesBody)])
        let provider = StenographerJudgeContext(client: try fake.client(), subject: "the report")
        let context = try #require(try await provider.context(intent: "send the report", principal: nil))
        #expect(context.subject == "the report")
        // Best grade first, as boundJudgeContext orders them
        #expect(context.truth?.map(\.id) == ["tb_1", "tb_3", "tb_2", "uv_1"])
        #expect(context.truth?.map(\.grade) == [.verified, .asserted, .migration, .advisory])
        #expect(context.transcript?.map(\.id) == ["m1", "m3"])
        #expect(context.transcript?.first?.role == .user)
        let search = try #require(fake.requests.first { $0.url?.path == "/truth/search" })
        #expect(search.url?.query?.contains("q=send%20the%20report") == true)
        #expect(search.url?.query?.contains("k=24") == true)
    }

    @Test("without a search route the context falls back to the current ledger; a dead stenographer yields no context, not an error")
    func judgeContextFallbacks() async throws {
        let fake = FakeStenographer(["/truth": (200, truthBody)])
        let context = try #require(try await StenographerJudgeContext(client: try fake.client()).context(intent: "x", principal: nil))
        #expect(context.truth?.count == 4)
        #expect(context.transcript == nil || context.transcript?.isEmpty == true)
        #expect(fake.paths == ["/truth/search", "/messages", "/truth"] || fake.paths == ["/messages", "/truth/search", "/truth"] || fake.paths == ["/truth/search", "/truth", "/messages"])

        let down = try StenographerClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: { _ in throw URLError(.cannotConnectToHost) })
        let none = try await StenographerJudgeContext(client: down).context(intent: "x", principal: nil)
        #expect(none == nil)
    }

    @Test("a stenographer slower than the budget answers no context")
    func judgeContextTimeout() async throws {
        let slow = try StenographerClient(baseURL: URL(string: "http://127.0.0.1:8787")!, transport: { request in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let started = Date()
        let context = try await StenographerJudgeContext(client: slow, timeout: 0.1).context(intent: "x", principal: nil)
        #expect(context == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test("consult posts the assertion as canonical JSON and reads the verdict; advice stats are nil when no model is configured")
    func consultAndStats() async throws {
        let fake = FakeStenographer([
            "/advice/consult": (200, #"{"adviser":"d1","model":"d1-omni-600M","contradicts":0.82,"cites":"tb_1","entries":[{"id":"tb_1"},{"id":"tb_3"}]}"#),
            "/advice/stats": (404, #"{"error":"no decision model"}"#),
            "/advice": (200, #"[{"id":"adv_1","kind":"objection","subjectId":"obj_1","adviser":"d1","model":"m","reasserts":0.9,"grade":"rewarded","truth":"sustained"}]"#),
        ])
        let client = try fake.client()
        let verdict = try await client.consult("the API lives on port 8080", k: 3)
        #expect(verdict.adviser == "d1" && verdict.contradicts == 0.82 && verdict.cites == "tb_1" && verdict.entryIds == ["tb_1", "tb_3"])
        let sent = fake.requests[0]
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: sent.httpBody!, as: UTF8.self) == #"{"assertion":"the API lives on port 8080","k":3}"#)
        #expect(try await client.adviceStats() == nil)
        let advice = try await client.advice(graded: true)
        #expect(advice.map(\.id) == ["adv_1"])
        #expect(advice[0].reasserts == 0.9 && advice[0].grade == "rewarded" && advice[0].truth == "sustained")
        #expect(fake.requests[2].url?.query?.contains("graded=true") == true)
    }

    @Test("objections carry the decision model's advice; notary routes need the secret and ids are checked before they reach a path")
    func objectionsAndNotary() async throws {
        let fake = FakeStenographer([
            "/flags": (200, #"[{"id":"obj_1","sessionId":"s1","messageId":"m9","tbId":"tb_1","objection":"contradicts tb_1","transcriptLine":"port 8080","status":"pending","delivered":true,"advice":{"id":"adv_1","kind":"objection","reasserts":0.1}}]"#),
            "/proposals/p_1/notarize": (200, #"{"ok":true}"#),
        ])
        let objections = try await fake.client().objections(includeShadow: true)
        #expect(objections.count == 1)
        #expect(objections[0].advice?.reasserts == 0.1)
        #expect(fake.requests[0].url?.query == "include=shadow")

        await #expect(throws: StenographerClientError.self) { try await fake.client().notarize("p_1", notary: "alice") }
        let result = try await fake.client(notarySecret: "n").notarize("p_1", notary: "alice")
        #expect(result["ok"]?.boolValue == true)
        let notarized = try #require(fake.requests.last)
        #expect(notarized.value(forHTTPHeaderField: "X-Notary-Secret") == "n")
        await #expect(throws: StenographerClientError.self) { try await fake.client().derivation(of: "../status") }
        #expect(StenographerClient.isPlainId("tb_1-a") && !StenographerClient.isPlainId("a/b") && !StenographerClient.isPlainId(""))
    }

    @Test("the launch line runs the TypeScript stenographer through npx with the chosen mode, port and decision model")
    func launchArguments() {
        let launch = StenographerLaunch(logPath: "/var/log/my app.log", statePath: "./state.db", restPort: 9001, adapter: "openclaw",
                                        objections: "deliver", objectionChannels: ["http://127.0.0.1:8081/channels/c1"], decisionModel: "d1",
                                        profile: "agent", packageVersion: "1.1.0", extraArgs: ["--verbose"])
        #expect(launch.arguments == [
            "npx", "-y", "@stenographer/core@1.1.0", "start", "/var/log/my app.log", "./state.db", "--mode", "daemon", "--rest-port", "9001",
            "--adapter", "openclaw", "--objections", "deliver", "--objection-channel", "http://127.0.0.1:8081/channels/c1",
            "--decision-model", "d1", "--profile", "agent", "--verbose",
        ])
        #expect(launch.shellCommand.contains("'/var/log/my app.log'"))
        #expect(StenographerLaunch(logPath: "a.log").arguments == ["npx", "-y", "@stenographer/core", "start", "a.log", "--mode", "daemon", "--rest-port", "8787"])
    }
}
