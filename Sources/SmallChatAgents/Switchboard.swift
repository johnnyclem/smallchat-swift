import Foundation

// MARK: - Switchboard
//
// Claude Code delivers into a *running* session only through its own
// cross-session messaging (`SendMessage` → the target's inbox socket; the
// socket's wire format isn't a public contract). So smallchat keeps one
// small headless session — the switchboard — whose only tools are
// `SendMessage` and `ListAgents`. The app writes relay commands to its
// stdin; it forwards them verbatim; agents reply to it by name, and it
// echoes their replies back in a fixed envelope the app parses.
//
// Delivery semantics come from Claude Code: the receiver reads the message
// between tool calls during a turn (a running tool is never interrupted),
// or starts a new turn when idle.

public enum SwitchboardProtocol {
    public static let defaultName = "smallchat"

    public static func systemPrompt(name: String) -> String {
        """
        You are "\(name)", the switchboard for the smallchat desktop app. You relay \
        messages between the human user (who talks to you only through the app) and \
        their other Claude Code sessions. You never do any other work, never answer \
        questions yourself, and never add commentary.

        The app sends you commands. Handle each one exactly as follows.

        1) A command of this form:
        RELAY <ticket>
        TO: <session name>
        CWD: <working directory, to disambiguate same-named sessions>
        ---
        <body>

        Call SendMessage once, addressed to that session, with <body> copied verbatim \
        (no summary, no additions, no removals). Then output exactly one line:
        DELIVERED <ticket>
        or, if the send was refused or held:
        FAILED <ticket> <short reason>

        2) The command LIST: call ListAgents, then output one line per session on this \
        machine, in this exact form, and nothing else:
        AGENT {"name":"<name>","cwd":"<working directory or empty>","status":"<status or empty>"}

        3) When a message from another session arrives (not an app command), output \
        exactly this and nothing else, copying the message verbatim:
        INBOUND <sender session name>
        <message text>
        END_INBOUND
        Do not reply to the sender. The app shows it to the user.
        """
    }

    /// Relay command text for one delivery.
    public static func relayCommand(ticket: String, to name: String, cwd: String, body: String) -> String {
        "RELAY \(ticket)\nTO: \(name)\nCWD: \(cwd)\n---\n\(body)"
    }

    /// Footer appended to relayed prompts so the agent knows where replies go.
    public static func replyHint(switchboardName: String) -> String {
        "\n\n(Sent via smallchat. Reply with SendMessage to \"\(switchboardName)\" — the user reads it there.)"
    }

    public enum Output: Sendable, Equatable {
        case delivered(ticket: String)
        case failed(ticket: String, reason: String)
        case agent(name: String, cwd: String, status: String)
        case inbound(sender: String, text: String)
    }

    /// Parse the switchboard's assistant text into protocol outputs.
    /// Unrecognized prose is ignored.
    public static func parse(_ text: String) -> [Output] {
        var outputs: [Output] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DELIVERED ") {
                outputs.append(.delivered(ticket: String(line.dropFirst("DELIVERED ".count)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("FAILED ") {
                let rest = line.dropFirst("FAILED ".count)
                let parts = rest.split(separator: " ", maxSplits: 1)
                if let ticket = parts.first {
                    outputs.append(.failed(ticket: String(ticket), reason: parts.count > 1 ? String(parts[1]) : "unknown"))
                }
            } else if line.hasPrefix("AGENT ") {
                let json = line.dropFirst("AGENT ".count)
                if let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                   let name = obj["name"] as? String, !name.isEmpty {
                    outputs.append(.agent(
                        name: name,
                        cwd: (obj["cwd"] as? String) ?? "",
                        status: (obj["status"] as? String) ?? ""
                    ))
                }
            } else if line.hasPrefix("INBOUND ") {
                let sender = String(line.dropFirst("INBOUND ".count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != "END_INBOUND" {
                    body.append(lines[j])
                    j += 1
                }
                outputs.append(.inbound(sender: sender.hasPrefix("@") ? String(sender.dropFirst()) : sender,
                                        text: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                i = j
            }
            i += 1
        }
        return outputs
    }
}

public struct SwitchboardError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// Owns the switchboard process: lazily launched, relaunched after a crash.
public actor Switchboard {
    public let name: String
    private let executable: String
    private let model: String
    private let cwd: String?
    private var process: ClaudeProcess?
    private var readTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var listWaiter: CheckedContinuation<[SwitchboardProtocol.Output], Never>?
    private var listed: [SwitchboardProtocol.Output] = []
    private var nextTicket = 1
    private let inboundContinuation: AsyncStream<(sender: String, text: String)>.Continuation

    /// Replies agents sent to the switchboard.
    public nonisolated let inbound: AsyncStream<(sender: String, text: String)>

    public init(executable: String, name: String = SwitchboardProtocol.defaultName, model: String = "haiku", cwd: String? = nil) {
        self.executable = executable
        self.name = name
        self.model = model
        self.cwd = cwd
        var cont: AsyncStream<(sender: String, text: String)>.Continuation!
        inbound = AsyncStream { cont = $0 }
        inboundContinuation = cont
    }

    /// Relay `body` to the session Claude Code knows as `claudeName`.
    /// Returns once the switchboard confirms the SendMessage.
    public func relay(to claudeName: String, cwd targetCwd: String, body: String, timeout: Duration = .seconds(120)) async throws {
        let process = try ensureRunning()
        let ticket = "t\(nextTicket)"
        nextTicket += 1
        let command = SwitchboardProtocol.relayCommand(ticket: ticket, to: claudeName, cwd: targetCwd, body: body)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.awaitTicket(ticket) {
                    process.send(line: StreamJSON.userMessageLine(command))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                await self.fail(ticket, reason: "switchboard timed out")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Ask Claude Code which sessions are reachable (names as it knows them).
    public func listAgents() async throws -> [(name: String, cwd: String, status: String)] {
        let process = try ensureRunning()
        let outputs: [SwitchboardProtocol.Output] = await withCheckedContinuation { cont in
            listWaiter?.resume(returning: listed)
            listWaiter = cont
            listed = []
            process.send(line: StreamJSON.userMessageLine("LIST"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.finishList()
            }
        }
        return outputs.compactMap {
            if case .agent(let name, let cwd, let status) = $0 { return (name, cwd, status) }
            return nil
        }
    }

    public func shutdown() {
        process?.closeInput()
        process?.terminate()
        process = nil
        readTask?.cancel()
        failAll("switchboard stopped")
    }

    // MARK: Internals

    private func awaitTicket(_ ticket: String, send: @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending[ticket] = cont
            send()
        }
    }

    private func finishList() {
        guard let waiter = listWaiter else { return }
        listWaiter = nil
        waiter.resume(returning: listed)
    }

    private func fail(_ ticket: String, reason: String) {
        pending.removeValue(forKey: ticket)?.resume(throwing: SwitchboardError(reason: reason))
    }

    private func failAll(_ reason: String) {
        for (_, cont) in pending { cont.resume(throwing: SwitchboardError(reason: reason)) }
        pending.removeAll()
        listWaiter?.resume(returning: listed)
        listWaiter = nil
    }

    private func ensureRunning() throws -> ClaudeProcess {
        if let process, process.isRunning { return process }
        let invocation = ClaudeCommand.switchboard(
            executable: executable, name: name,
            systemPrompt: SwitchboardProtocol.systemPrompt(name: name),
            model: model, cwd: cwd
        )
        let process = ClaudeProcess(invocation)
        try process.start()
        self.process = process
        readTask = Task { [weak self] in
            do {
                for try await line in process.lines {
                    await self?.handle(line: line)
                }
                await self?.processEnded(reason: "switchboard exited")
            } catch {
                await self?.processEnded(reason: String(describing: error))
            }
        }
        return process
    }

    private func processEnded(reason: String) {
        process = nil
        failAll(reason)
    }

    private func handle(line: String) {
        guard let event = StreamJSON.parse(line: line) else { return }
        switch event {
        case .assistantText(let text):
            for output in SwitchboardProtocol.parse(text) {
                switch output {
                case .delivered(let ticket):
                    pending.removeValue(forKey: ticket)?.resume()
                case .failed(let ticket, let reason):
                    fail(ticket, reason: reason)
                case .agent:
                    listed.append(output)
                case .inbound(let sender, let text):
                    inboundContinuation.yield((sender, text))
                }
            }
        case .result:
            // A LIST turn ends with its result. Results of other turns (a
            // relay still in flight, an inbound reply) arrive with nothing
            // listed yet and are skipped; the timeout covers an empty list.
            if !listed.isEmpty { finishList() }
        default:
            break
        }
    }
}
