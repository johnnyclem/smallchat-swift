import Foundation

// MARK: - Transport

public enum TransportEvent: Sendable, Equatable {
    /// A new session was created; carries its Claude Code session id.
    case sessionStarted(String)
    /// Handed off to the recipient.
    case delivered
    /// Something the agent is doing (tool use), for the typing indicator.
    case activity(String)
    /// The agent answered within this send (headless resume).
    case reply(String)
}

/// A reply that arrived out of band (an agent messaged the switchboard).
public struct InboundReply: Sendable, Equatable {
    /// The sender's name as Claude Code knows it.
    public let senderName: String
    public let text: String
}

/// Moves text between smallchat and Claude Code sessions.
public protocol AgentTransport: Sendable {
    /// Deliver `body` to `agent`. Live sessions get it through inter-agent
    /// messaging (their reply arrives later on `inbound`); stopped sessions
    /// are resumed headlessly and reply inside the stream.
    func send(_ body: String, to agent: AgentSession, style: DeliveryStyle) -> AsyncThrowingStream<TransportEvent, Error>

    /// Create a new named session in `cwd` with a first prompt.
    func startSession(name: String, cwd: String, prompt: String) -> AsyncThrowingStream<TransportEvent, Error>

    /// Ask the stenographer (a headless session preloaded with the ledger).
    func askStenographer(_ prompt: String, brief: String, resumeSessionId: String?, cwd: String?) -> AsyncThrowingStream<TransportEvent, Error>

    /// Out-of-band replies from live agents.
    var inbound: AsyncStream<InboundReply> { get }

    /// Claude Code's own names for live sessions, when the transport can list them.
    func listLiveNames() async -> [(name: String, cwd: String)]

    /// Stop any processes the transport keeps running (the switchboard).
    /// Called when the messenger replaces the transport.
    func shutdown() async
}

public enum AgentTransportError: Error, Equatable, CustomStringConvertible {
    /// The session is running, but Claude Code hasn't reported its name, so
    /// it can't be messaged; resuming it would run a second copy of it.
    case liveSessionUnnamed(handle: String)

    public var description: String {
        switch self {
        case .liveSessionUnnamed(let handle):
            return "@\(handle) is running, but Claude Code hasn't reported its session name, so smallchat can't message it. "
                + "It wasn't resumed: that would run a second copy of the session. Try again once its name shows, or after it stops."
        }
    }
}

/// One headless turn per session at a time. A second `--resume` of a session
/// waits for the first to finish instead of appending a divergent branch to
/// the same transcript.
actor SessionTurnGate {
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: String) async {
        if busy.insert(id).inserted { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            next.resume()  // the turn passes to the next waiter; `id` stays busy
        } else {
            busy.remove(id)
        }
    }
}

// MARK: - Claude Code

public final class ClaudeCodeTransport: AgentTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        public var switchboardName: String = SwitchboardProtocol.defaultName
        public var switchboardModel: String = "haiku"
        public var stenographerModel: String = "sonnet"
        /// Fixed switchboard framing nonce, for tests. nil: a fresh random one.
        public var switchboardNonce: String?
        /// The switchboard's working directory: one of its own, so no
        /// project's settings or CLAUDE.md apply to it.
        public var switchboardDirectory: String = ClaudeCodeTransport.defaultSwitchboardDirectory()

        public init(executable: String) { self.executable = executable }
    }

    private let config: Configuration
    private let switchboard: Switchboard
    private let turns = SessionTurnGate()
    public let inbound: AsyncStream<InboundReply>

    /// `<Application Support>/SmallChat/switchboard`.
    public static func defaultSwitchboardDirectory() -> String {
        MessengerStore.defaultURL().deletingLastPathComponent().appendingPathComponent("switchboard", isDirectory: true).path
    }

    public init(config: Configuration) {
        self.config = config
        let switchboard = Switchboard(
            executable: config.executable,
            name: config.switchboardName,
            model: config.switchboardModel,
            cwd: config.switchboardDirectory,
            nonce: config.switchboardNonce ?? SwitchboardProtocol.makeNonce()
        )
        self.switchboard = switchboard
        inbound = AsyncStream { continuation in
            let task = Task {
                for await (sender, text) in switchboard.inbound {
                    continuation.yield(InboundReply(senderName: sender, text: text))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ body: String, to agent: AgentSession, style: DeliveryStyle) -> AsyncThrowingStream<TransportEvent, Error> {
        if agent.isLive {
            // A running session is only ever messaged, never resumed.
            guard let name = agent.claudeName else {
                return AsyncThrowingStream { $0.finish(throwing: AgentTransportError.liveSessionUnnamed(handle: agent.handle)) }
            }
            let switchboard = self.switchboard
            let hint = SwitchboardProtocol.replyHint(switchboardName: config.switchboardName)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await switchboard.relay(to: name, cwd: agent.cwd, body: body + hint)
                        continuation.yield(.delivered)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        // Not running anywhere: resume it headlessly for one turn.
        return run(ClaudeCommand.resume(
            executable: config.executable, sessionId: agent.id, prompt: body, cwd: agent.cwd
        ), oneTurnAtATimeFor: agent.id)
    }

    public func startSession(name: String, cwd: String, prompt: String) -> AsyncThrowingStream<TransportEvent, Error> {
        run(ClaudeCommand.newSession(executable: config.executable, name: name, prompt: prompt, cwd: cwd))
    }

    public func askStenographer(_ prompt: String, brief: String, resumeSessionId: String?, cwd: String?) -> AsyncThrowingStream<TransportEvent, Error> {
        run(ClaudeCommand.stenographer(
            executable: config.executable, prompt: prompt, systemPrompt: brief,
            resumeSessionId: resumeSessionId, model: config.stenographerModel, cwd: cwd
        ), oneTurnAtATimeFor: resumeSessionId)
    }

    public func listLiveNames() async -> [(name: String, cwd: String)] {
        ((try? await switchboard.listAgents()) ?? []).map { ($0.name, $0.cwd) }
    }

    public func shutdown() async {
        await switchboard.shutdown()
    }

    /// Run one headless turn and translate its stream into transport events.
    /// With `sessionId`, the turn waits until no other turn of that session
    /// is running.
    private func run(_ invocation: ClaudeInvocation, oneTurnAtATimeFor sessionId: String? = nil) -> AsyncThrowingStream<TransportEvent, Error> {
        let turns = self.turns
        return AsyncThrowingStream { continuation in
            let process = ClaudeProcess(invocation)
            let task = Task {
                if let sessionId { await turns.acquire(sessionId) }
                await Self.drive(process, into: continuation)
                if let sessionId { await turns.release(sessionId) }
            }
            continuation.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
        }
    }

    private static func drive(_ process: ClaudeProcess, into continuation: AsyncThrowingStream<TransportEvent, Error>.Continuation) async {
        do {
            try Task.checkCancellation()
            try process.start()
            continuation.yield(.delivered)
            var lastText: String?
            var replied = false
            for try await line in process.lines {
                switch StreamJSON.parse(line: line) {
                case .initialized(let id, _):
                    continuation.yield(.sessionStarted(id))
                case .toolUse(let name, let input):
                    let summary = TranscriptActivity.summarize(tool: name, input: input)
                    continuation.yield(.activity(summary.isEmpty ? name : "\(name) · \(summary)"))
                case .assistantText(let text):
                    lastText = text
                case .result(let text, let isError, _, _):
                    if isError {
                        throw SwitchboardError(reason: text ?? "the turn failed")
                    }
                    if let reply = (text?.isEmpty == false ? text : lastText) {
                        continuation.yield(.reply(reply))
                        replied = true
                    }
                default:
                    break
                }
            }
            if Task.isCancelled { process.terminate() }
            if !replied, let lastText { continuation.yield(.reply(lastText)) }
            continuation.finish()
        } catch {
            process.terminate()
            continuation.finish(throwing: error)
        }
    }
}

// MARK: - Unavailable

/// Stand-in when the `claude` CLI can't be found: every send fails with a
/// message pointing at Settings, and the rest of the app keeps working.
public struct UnavailableTransport: AgentTransport {
    public let inbound = AsyncStream<InboundReply> { $0.finish() }

    public init() {}

    private func failing() -> AsyncThrowingStream<TransportEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ClaudeProcessError.executableNotFound) }
    }

    public func send(_ body: String, to agent: AgentSession, style: DeliveryStyle) -> AsyncThrowingStream<TransportEvent, Error> { failing() }
    public func startSession(name: String, cwd: String, prompt: String) -> AsyncThrowingStream<TransportEvent, Error> { failing() }
    public func askStenographer(_ prompt: String, brief: String, resumeSessionId: String?, cwd: String?) -> AsyncThrowingStream<TransportEvent, Error> { failing() }
    public func listLiveNames() async -> [(name: String, cwd: String)] { [] }
    public func shutdown() async {}
}

// MARK: - Factory

public enum AgentTransports {
    /// The real transport when `claude` is installed, else `UnavailableTransport`.
    public static func make(settings: MessengerSettings) -> any AgentTransport {
        guard let executable = ClaudeCommand.locateExecutable(preferred: settings.claudePath) else {
            return UnavailableTransport()
        }
        var config = ClaudeCodeTransport.Configuration(executable: executable)
        config.switchboardModel = settings.switchboardModel
        config.stenographerModel = settings.stenographerModel
        return ClaudeCodeTransport(config: config)
    }
}

// MARK: - Mock

/// Scripted transport for previews and tests: every agent echoes.
public final class MockAgentTransport: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(body: String, agentId: String, style: DeliveryStyle)] = []
    private var _shutdownCount = 0
    private let inboundContinuation: AsyncStream<InboundReply>.Continuation
    public let inbound: AsyncStream<InboundReply>
    /// Builds each agent's reply; nil means "live agent — reply later via inbound".
    public var replyBuilder: @Sendable (String, AgentSession) -> String?

    public init(replyBuilder: @escaping @Sendable (String, AgentSession) -> String? = { body, agent in
        "@\(agent.handle) got: \(body.split(separator: "\n").last.map(String.init) ?? "")"
    }) {
        self.replyBuilder = replyBuilder
        var cont: AsyncStream<InboundReply>.Continuation!
        inbound = AsyncStream { cont = $0 }
        inboundContinuation = cont
    }

    public var sent: [(body: String, agentId: String, style: DeliveryStyle)] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    /// How many times `shutdown()` was called.
    public var shutdownCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _shutdownCount
    }

    public func shutdown() async {
        lock.withLock { _shutdownCount += 1 }
    }

    /// Simulate a live agent replying via the switchboard.
    public func deliverInbound(_ reply: InboundReply) {
        inboundContinuation.yield(reply)
    }

    public func send(_ body: String, to agent: AgentSession, style: DeliveryStyle) -> AsyncThrowingStream<TransportEvent, Error> {
        lock.lock()
        _sent.append((body, agent.id, style))
        lock.unlock()
        let reply = replyBuilder(body, agent)
        return AsyncThrowingStream { continuation in
            continuation.yield(.delivered)
            if style == .prompt, let reply { continuation.yield(.reply(reply)) }
            continuation.finish()
        }
    }

    public func startSession(name: String, cwd: String, prompt: String) -> AsyncThrowingStream<TransportEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.sessionStarted("mock-\(name)"))
            continuation.yield(.reply("Hi, I'm \(name)."))
            continuation.finish()
        }
    }

    public func askStenographer(_ prompt: String, brief: String, resumeSessionId: String?, cwd: String?) -> AsyncThrowingStream<TransportEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.sessionStarted(resumeSessionId ?? "mock-stenographer"))
            continuation.yield(.reply("On the record."))
            continuation.finish()
        }
    }

    public func listLiveNames() async -> [(name: String, cwd: String)] { [] }
}
