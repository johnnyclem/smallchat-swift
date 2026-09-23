import Foundation
import Testing
@testable import SmallChatAgents

@Suite("stream-json")
struct StreamJSONTests {
    @Test("parses the shapes we use")
    func shapes() {
        #expect(StreamJSON.parse(line: #"{"type":"system","subtype":"init","session_id":"s1","model":"m"}"#)
                == .initialized(sessionId: "s1", model: "m"))
        #expect(StreamJSON.parse(line: #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"hi"},{"type":"text","text":"there"}]}}"#)
                == .assistantText("hi\nthere"))
        #expect(StreamJSON.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#)
                == .toolUse(name: "Bash", input: ["command": "ls"]))
        #expect(StreamJSON.parse(line: #"{"type":"assistant","parent_tool_use_id":"tu_1","message":{"content":[{"type":"text","text":"sub"}]}}"#)
                == .other)
        #expect(StreamJSON.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1","total_cost_usd":0.01}"#)
                == .result(text: "done", isError: false, sessionId: "s1", costUSD: 0.01))
        #expect(StreamJSON.parse(line: "not json") == nil)
        #expect(StreamJSON.parse(line: #"{"type":"brand_new_event"}"#) == .other)
    }

    @Test("user message line is valid stream-json input")
    func inputLine() throws {
        let line = StreamJSON.userMessageLine("hello \"there\"\nsecond")
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "user")
        #expect((obj["message"] as? [String: Any])?["content"] as? String == "hello \"there\"\nsecond")
        #expect(!line.contains("\n"))
    }
}

@Suite("Switchboard protocol")
struct SwitchboardProtocolTests {
    @Test("parses delivery receipts, listings, and inbound envelopes")
    func parse() {
        let text = """
        DELIVERED t1
        FAILED t2 held for approval
        AGENT {"name":"instrument-62","cwd":"/r/instrument","status":"busy"}
        some stray prose
        INBOUND @instrument-62
        Both directions broken.
        Line two.
        END_INBOUND
        """
        #expect(SwitchboardProtocol.parse(text) == [
            .delivered(ticket: "t1"),
            .failed(ticket: "t2", reason: "held for approval"),
            .agent(name: "instrument-62", cwd: "/r/instrument", status: "busy"),
            .inbound(sender: "instrument-62", text: "Both directions broken.\nLine two."),
        ])
    }

    @Test("relay command carries the body verbatim")
    func relay() {
        let command = SwitchboardProtocol.relayCommand(ticket: "t9", to: "api", cwd: "/r", body: "line1\nline2")
        #expect(command == "RELAY t9\nTO: api\nCWD: /r\n---\nline1\nline2")
    }
}

@Suite("Claude invocations")
struct ClaudeCommandTests {
    @Test("resume is a documented headless turn")
    func resume() {
        let inv = ClaudeCommand.resume(executable: "/bin/claude", sessionId: "S", prompt: "hi", cwd: "/r")
        #expect(inv.arguments == ["-p", "hi", "--resume", "S", "--output-format", "stream-json", "--verbose"])
        #expect(inv.workingDirectory == "/r")
    }

    @Test("switchboard may only message and list")
    func switchboard() {
        let args = ClaudeCommand.switchboard(executable: "c", name: "smallchat", systemPrompt: "p", model: "haiku", cwd: nil).arguments
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed == "SendMessage,ListAgents")
        #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "dontAsk")
        #expect(args.contains("--input-format"))
    }

    @Test("locates claude in known install dirs")
    func locate() {
        let found = ClaudeCommand.locateExecutable(
            environment: ["HOME": "/Users/j", "PATH": "/usr/bin"],
            fileExists: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(found == "/opt/homebrew/bin/claude")
        #expect(ClaudeCommand.locateExecutable(environment: ["HOME": "/h", "PATH": ""], fileExists: { _ in false }) == nil)
    }
}

@Suite("Session discovery")
struct DiscoveryTests {
    func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)")
        let project = home.appendingPathComponent("projects/-Users-j-Repos-instrument")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)

        let transcript = """
        {"type":"ai-title","aiTitle":"Swift compat archives","sessionId":"11111111-1111-1111-1111-111111111111"}
        {"type":"user","cwd":"/Users/j/Repos/instrument","gitBranch":"qp-27110","timestamp":"2026-09-22T10:00:00.000Z","sessionId":"11111111-1111-1111-1111-111111111111","message":{"role":"user","content":"hi"}}
        {"type":"assistant","cwd":"/Users/j/Repos/instrument","timestamp":"2026-09-22T11:30:00Z","sessionId":"11111111-1111-1111-1111-111111111111","message":{"role":"assistant","content":[]}}
        {"type":"custom-title","customTitle":"compat consolidation","sessionId":"11111111-1111-1111-1111-111111111111"}
        not json at all
        """
        try transcript.write(to: project.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl"), atomically: true, encoding: .utf8)
        try "{\"type\":\"user\",\"cwd\":\"/Users/j/Repos/instrument\",\"timestamp\":\"2026-09-01T00:00:00Z\"}\n"
            .write(to: project.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl"), atomically: true, encoding: .utf8)

        let live = """
        {"pid":4242,"sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/Users/j/Repos/instrument","kind":"interactive","name":"instrument-62","nameSource":"user","status":"busy","updatedAt":1790122346191}
        """
        try live.write(to: home.appendingPathComponent("sessions/4242.json"), atomically: true, encoding: .utf8)
        let dead = #"{"pid":9999,"sessionId":"22222222-2222-2222-2222-222222222222","status":"idle"}"#
        try dead.write(to: home.appendingPathComponent("sessions/9999.json"), atomically: true, encoding: .utf8)
        return home
    }

    @Test("merges transcripts with the live registry")
    func scan() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var scanner = ClaudeSessionScanner(claudeHome: home)
        scanner.isProcessAlive = { $0 == 4242 }
        let sessions = scanner.scan()

        #expect(sessions.count == 2)
        let live = try #require(sessions.first { $0.sessionId.hasPrefix("1111") })
        #expect(live.cwd == "/Users/j/Repos/instrument")
        #expect(live.gitBranch == "qp-27110")
        #expect(live.title == "compat consolidation")
        #expect(live.live?.activity == .busy)
        #expect(live.live?.agentKind == .interactive)
        #expect(live.live?.nameIsUserChosen == true)

        let stopped = try #require(sessions.first { $0.sessionId.hasPrefix("2222") })
        #expect(stopped.live == nil, "dead pid must not count as live")
    }

    @Test("reads the tail of large transcripts")
    func tailWindow() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("projects/-Users-j-Repos-instrument/33333333-3333-3333-3333-333333333333.jsonl")
        var text = #"{"type":"user","cwd":"/big","timestamp":"2026-01-01T00:00:00Z","sessionId":"33333333-3333-3333-3333-333333333333"}"# + "\n"
        let filler = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 900))"}}"# + "\n"
        text += String(repeating: filler, count: 400)
        text += #"{"type":"user","cwd":"/big","timestamp":"2026-03-01T00:00:00Z"}"# + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        var scanner = ClaudeSessionScanner(claudeHome: home)
        scanner.windowBytes = 16 * 1024
        let summary = try #require(scanner.summarize(transcriptAt: file))
        #expect(summary.cwd == "/big")
        #expect(summary.lastTimestamp == parseISODate("2026-03-01T00:00:00Z"))
    }
}

/// Drives the real process plumbing against a fake `claude` shell script.
@Suite("Claude process plumbing")
struct ProcessPlumbingTests {
    func fakeClaude(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test("headless resume streams activity and the final reply")
    func resume() async throws {
        let exe = try fakeClaude("""
        echo '{"type":"system","subtype":"init","session_id":"S1"}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"all green"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"all green","session_id":"S1"}'
        """)
        let transport = ClaudeCodeTransport(config: .init(executable: exe))
        let agent = AgentSession(id: "S1", handle: "a", cwd: FileManager.default.temporaryDirectory.path, lastActivity: Date())
        var events: [TransportEvent] = []
        for try await event in transport.send("hi", to: agent, style: .prompt) { events.append(event) }
        #expect(events == [.delivered, .sessionStarted("S1"), .activity("Bash"), .reply("all green")])
    }

    @Test("a failing CLI surfaces its exit status")
    func failure() async throws {
        let exe = try fakeClaude("echo 'boom' >&2\nexit 3\n")
        let transport = ClaudeCodeTransport(config: .init(executable: exe))
        let agent = AgentSession(id: "S1", handle: "a", cwd: "/", lastActivity: Date())
        await #expect(throws: ClaudeProcessError.exited(code: 3, stderr: "boom\n")) {
            for try await _ in transport.send("hi", to: agent, style: .prompt) {}
        }
    }

    @Test("live sessions go through the switchboard; inbound replies are parsed")
    func switchboardRelay() async throws {
        // Echo a receipt for each RELAY ticket, then one inbound reply.
        let exe = try fakeClaude(#"""
        while IFS= read -r line; do
          ticket=$(printf '%s' "$line" | grep -o 'RELAY t[0-9]*' | cut -d' ' -f2)
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"DELIVERED %s"}]}}\n' "$ticket"
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"INBOUND @api\\nready\\nEND_INBOUND"}]}}\n'
        done
        """#)
        let transport = ClaudeCodeTransport(config: .init(executable: exe))
        let agent = AgentSession(id: "L1", handle: "api", claudeName: "api", cwd: "/", lastActivity: Date(), activity: .idle)
        var events: [TransportEvent] = []
        for try await event in transport.send("status?", to: agent, style: .interrupt) { events.append(event) }
        #expect(events == [.delivered])

        var iterator = transport.inbound.makeAsyncIterator()
        let reply = await iterator.next()
        #expect(reply == InboundReply(senderName: "api", text: "ready"))
        await transport.shutdown()
    }
}
