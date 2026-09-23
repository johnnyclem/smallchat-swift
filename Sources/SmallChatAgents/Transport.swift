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
}

// MARK: - Claude Code

public final class ClaudeCodeTransport: AgentTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        public var switchboardName: String = SwitchboardProtocol.defaultName
        public var switchboardModel: String = "haiku"
        public var stenographerModel: String = "sonnet"

        public init(executable: String) { self.executable = executable }
    }

    private let config: Configuration
    private let switchboard: Switchboard
    public let inbound: AsyncStream<InboundReply>

    public init(config: Configuration) {
        self.config = config
        let switchboard = Switchboard(
            executable: config.executable,
            name: config.switchboardName,
            model: config.switchboardModel,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path
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
        if agent.isLive, let name = agent.claudeName {
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
        // Not running anywhere: resume it headlessly for one turn. (A live
        // session we can't name is also resumed rather than dropped.)
        return run(ClaudeCommand.resume(
            executable: config.executable, sessionId: agent.id, prompt: body, cwd: agent.cwd
        ))
    }

    public func startSession(name: String, cwd: String, prompt: String) -> AsyncThrowingStream<TransportEvent, Error> {
        run(ClaudeCommand.newSession(executable: config.executable, name: name, prompt: prompt, cwd: cwd))
    }

    public func askStenographer(_ prompt: String, brief: String, resumeSessionId: String?, cwd: String?) -> AsyncThrowingStream<TransportEvent, Error> {
        run(ClaudeCommand.stenographer(
            executable: config.executable, prompt: prompt, systemPrompt: brief,
            resumeSessionId: resumeSessionId, model: config.stenographerModel, cwd: cwd
        ))
    }

    public func listLiveNames() async -> [(name: String, cwd: String)] {
        ((try? await switchboard.listAgents()) ?? []).map { ($0.name, $0.cwd) }
    }

    public func shutdown() async {
        await switchboard.shutdown()
    }

    /// Run one headless turn and translate its stream into transport events.
    private func run(_ invocation: ClaudeInvocation) -> AsyncThrowingStream<TransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = ClaudeProcess(invocation)
            let task = Task {
                do {
                    try process.start()
                    process.closeInput()
                    continuation.yield(.delivered)
                    var lastText: String?
                    var replied = false
                    for try await line in process.lines {
                        switch StreamJSON.parse(line: line) {
                        case .initialized(let id, _):
                            continuation.yield(.sessionStarted(id))
                        case .toolUse(let name, _):
                            continuation.yield(.activity(name))
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
                    if !replied, let lastText { continuation.yield(.reply(lastText)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
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
