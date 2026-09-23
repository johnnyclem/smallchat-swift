import Foundation
import Testing
@testable import SmallChatAgents

@Suite("Transcript activity")
struct TranscriptActivityTests {
    static func assistant(_ blocks: String, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"2026-09-23T10:00:00Z","message":{"content":[\#(blocks)]}}"#
    }
    static func result(_ id: String, error: Bool = false) -> String {
        #"{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error)}]}}"#
    }

    @Test("pending tool_use is current; results finish steps")
    func current() {
        let lines = [
            Self.assistant(#"{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/r/Sources/App.swift"}}"#),
            Self.result("t1"),
            Self.assistant(#"{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"xcodebuild -scheme App","description":"Build the app"}}"#),
        ]
        let snap = TranscriptActivity.parse(lines: lines)
        #expect(snap.current?.label == "Bash · Build the app")
        #expect(snap.recent.map(\.id) == ["t1", "t2"])
        #expect(snap.recent[0].finished)
        #expect(snap.recent[0].label == "Read · App.swift")
    }

    @Test("errors, sidechains, prose, and the recent window")
    func details() {
        var lines = (1...7).flatMap { i in
            [Self.assistant(#"{"type":"tool_use","id":"t\#(i)","name":"Grep","input":{"pattern":"p\#(i)"}}"#), Self.result("t\(i)", error: i == 7)]
        }
        lines.append(Self.assistant(#"{"type":"tool_use","id":"sub","name":"Bash","input":{"command":"ls"}}"#, sidechain: true))
        lines.append(Self.assistant(#"{"type":"text","text":"\nFound a real bug in my own detector.\nMore."}"#))
        lines.append("garbage")
        let snap = TranscriptActivity.parse(lines: lines)
        #expect(snap.current == nil, "sidechain tool_use must not count")
        #expect(snap.recent.count == TranscriptActivity.maxRecent)
        #expect(snap.recent.last?.failed == true)
        #expect(snap.lastSaid == "Found a real bug in my own detector.")
    }

    @Test("summaries pick the informative field and truncate")
    func summaries() {
        #expect(TranscriptActivity.summarize(tool: "Bash", input: ["command": "a\nb"]) == "a")
        #expect(TranscriptActivity.summarize(tool: "WebFetch", input: ["url": "https://x.dev"]) == "https://x.dev")
        #expect(TranscriptActivity.summarize(tool: "Custom", input: ["b": "2", "a": "1"]) == "1")
        #expect(TranscriptActivity.summarize(tool: "Bash", input: ["command": String(repeating: "x", count: 200)]).count == TranscriptActivity.maxSummary)
    }
}

@MainActor
@Suite("Live activity in the model")
struct LiveActivityModelTests {
    @Test("live sessions stream their current tool; stopped ones clear")
    func stream() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-act-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("projects/-r-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("dddd-4.jsonl")
        try (TranscriptActivityTests.assistant(#"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}"#) + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        try #"{"pid":9,"sessionId":"dddd-4","cwd":"/r/app","status":"busy"}"#
            .write(to: home.appendingPathComponent("sessions/9.json"), atomically: true, encoding: .utf8)

        var scanner = ClaudeSessionScanner(claudeHome: home)
        scanner.isProcessAlive = { _ in true }
        #expect(scanner.transcriptPath(sessionId: "dddd-4", cwd: "/r/app") == transcript.path)

        let model = MessengerModel(store: MessengerStore(url: nil), transport: MockAgentTransport(), scanner: scanner)
        await model.refreshLive()
        #expect(model.liveActivity["dddd-4"]?.current?.label == "Bash · swift test")

        // The tool finishes: appended result is picked up on the next poll.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((TranscriptActivityTests.result("t1") + "\n").utf8))
        try handle.close()
        await model.refreshLive()
        #expect(model.liveActivity["dddd-4"]?.current == nil)
        #expect(model.liveActivity["dddd-4"]?.recent.first?.finished == true)

        // Process gone → no live activity.
        try FileManager.default.removeItem(at: home.appendingPathComponent("sessions/9.json"))
        await model.refreshLive()
        #expect(model.liveActivity["dddd-4"] == nil)
    }
}
