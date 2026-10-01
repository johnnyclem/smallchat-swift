import Foundation
import SmallChatTransport

// MARK: - Invocations

/// A fully-specified `claude` process launch. Pure data so argument
/// construction is unit-testable without spawning anything.
///
/// Text never goes on the command line: argv is size-capped (128 KB per
/// argument on Linux, about 1 MB in all on macOS), readable by every local
/// process, and a prompt starting with `-` would parse as a flag.
public struct ClaudeInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    /// Appended to Claude Code's system prompt through a private temporary
    /// file (`--append-system-prompt-file`, mode 0600), removed when the
    /// process exits.
    public var appendSystemPrompt: String?
    /// The turn's prompt, written to stdin as one stream-json user message,
    /// after which stdin closes. nil leaves stdin open for `send(line:)`.
    public var prompt: String?

    public init(
        executable: String, arguments: [String], workingDirectory: String? = nil,
        appendSystemPrompt: String? = nil, prompt: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.appendSystemPrompt = appendSystemPrompt
        self.prompt = prompt
    }
}

public enum ClaudeCommand {
    /// Headless, stream-json in and out.
    static let streamIO = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]

    /// What smallchat's own headless sessions (switchboard, stenographer)
    /// never get: MCP servers from any config (`--strict-mcp-config` without
    /// `--mcp-config`) and project or local settings from the working
    /// directory. Their tools come only from `--tools`, which is an allowlist:
    /// tools pre-approved in the user's settings don't exist in the session.
    static let isolation = ["--strict-mcp-config", "--setting-sources", "user"]

    /// The switchboard's only tools.
    public static let switchboardTools = "SendMessage,ListAgents"
    /// The stenographer's only tools: reading the chat's working directory.
    public static let stenographerTools = "Read,Grep,Glob"

    /// One headless turn on an existing session (documented resume path).
    public static func resume(
        executable: String, sessionId: String, prompt: String, cwd: String?
    ) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: streamIO + ["--resume", sessionId],
            workingDirectory: cwd,
            prompt: prompt
        )
    }

    /// Start a brand-new named session with its first prompt.
    public static func newSession(
        executable: String, name: String, prompt: String, cwd: String, model: String? = nil
    ) -> ClaudeInvocation {
        var args = streamIO + ["--name", name]
        if let model, !model.isEmpty { args += ["--model", model] }
        return ClaudeInvocation(executable: executable, arguments: args, workingDirectory: cwd, prompt: prompt)
    }

    /// The long-lived relay session. Its only tools are SendMessage and
    /// ListAgents (`--tools`), pre-approved so `dontAsk` doesn't deny them;
    /// inbound replies are accepted so agents can answer it. Run it in a
    /// directory of its own (see `ClaudeCodeTransport.defaultSwitchboardDirectory()`).
    public static func switchboard(
        executable: String, name: String, systemPrompt: String, model: String, cwd: String?
    ) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: streamIO + [
                "--name", name,
                "--model", model,
                "--tools", switchboardTools,
                "--allowedTools", switchboardTools,
                "--permission-mode", "dontAsk",
            ] + isolation + [
                "--settings", #"{"crossSessionInbound":"accept"}"#,
            ],
            workingDirectory: cwd,
            appendSystemPrompt: systemPrompt
        )
    }

    /// One stenographer turn: ledger preloaded via the system prompt. Its
    /// only tools read files; nothing is pre-approved, so under `dontAsk` it
    /// reads inside the chat's working directory and is denied everything
    /// else. Resumes its own session when it has one.
    public static func stenographer(
        executable: String, prompt: String, systemPrompt: String, resumeSessionId: String?,
        model: String, cwd: String?
    ) -> ClaudeInvocation {
        var args = streamIO + [
            "--model", model,
            "--tools", stenographerTools,
            "--permission-mode", "dontAsk",
        ] + isolation
        if let resumeSessionId { args += ["--resume", resumeSessionId] }
        return ClaudeInvocation(
            executable: executable, arguments: args, workingDirectory: cwd,
            appendSystemPrompt: systemPrompt, prompt: prompt
        )
    }

    /// Find the `claude` binary. GUI apps on macOS don't inherit the login
    /// shell's PATH, so the usual install locations are probed explicitly.
    public static func locateExecutable(
        preferred: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let preferred, !preferred.isEmpty {
            let expanded = (preferred as NSString).expandingTildeInPath
            if fileExists(expanded) { return expanded }
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/claude")
        }
        return candidates.first(where: fileExists)
    }
}

// MARK: - Process

public enum ClaudeProcessError: Error, Equatable, CustomStringConvertible {
    case executableNotFound
    case launchFailed(String)
    case exited(code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .executableNotFound:
            return "Couldn't find the `claude` CLI. Set its path in Settings."
        case .launchFailed(let reason):
            return "Couldn't launch claude: \(reason)"
        case .exited(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            return "claude exited with status \(code)" + (tail.isEmpty ? "" : ": \(tail)")
        }
    }
}

/// A running `claude` process with line-oriented stdout and optional stdin.
public final class ClaudeProcess: @unchecked Sendable {
    private let invocation: ClaudeInvocation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrText = ""
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    /// Private directory holding the system-prompt file, removed on exit.
    private var scratchDirectory: URL?

    /// stdout, one line per element. Finishes when the process exits; throws
    /// `ClaudeProcessError.exited` on a non-zero status.
    public let lines: AsyncThrowingStream<String, Error>

    public init(_ invocation: ClaudeInvocation) {
        self.invocation = invocation
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream { cont = $0 }
        continuation = cont

        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let cwd = invocation.workingDirectory, !cwd.isEmpty,
           FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public func start() throws {
        if let systemPrompt = invocation.appendSystemPrompt {
            let file = try writePrivateFile(systemPrompt, named: "system-prompt.md")
            process.arguments = invocation.arguments + ["--append-system-prompt-file", file.path]
        }
        do {
            try process.run()
        } catch {
            removeScratch()
            throw ClaudeProcessError.launchFailed(error.localizedDescription)
        }
        // The prompt goes in on its own thread: a prompt bigger than the pipe
        // buffer blocks until claude reads it, and a claude that exits early
        // must not take the app down with SIGPIPE.
        if let prompt = invocation.prompt {
            PipeIO.writeInBackground(
                Data((StreamJSON.userMessageLine(prompt) + "\n").utf8),
                to: stdinPipe.fileHandleForWriting,
                closeAfterwards: true
            )
        }
        // Blocking reads on background queues: stdout to EOF, stderr joined,
        // then the exit status. Finishing on EOF (not on the termination
        // callback, which races the last read) never drops the final line.
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let handle = stderrPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                stderrText += String(decoding: chunk, as: UTF8.self)
                if stderrText.count > 16_000 { stderrText = String(stderrText.suffix(8_000)) }
                lock.unlock()
            }
            stderrDone.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                consume(chunk)
            }
            stderrDone.wait()
            process.waitUntilExit()
            finish(status: process.terminationStatus)
        }
    }

    /// Write one line to stdin (for `--input-format stream-json`). Returns
    /// false when the process no longer reads its stdin.
    @discardableResult
    public func send(line: String) -> Bool {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        return PipeIO.writeAll(data, to: stdinPipe.fileHandleForWriting)
    }

    public func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    /// Write `text` to a new file in a fresh directory only this user can
    /// read (0700 directory, 0600 file).
    private func writePrivateFile(_ text: String, named name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("smallchat-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ClaudeProcessError.launchFailed("couldn't create a private directory for the system prompt: \(error.localizedDescription)")
        }
        let file = dir.appendingPathComponent(name)
        guard fm.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            try? fm.removeItem(at: dir)
            throw ClaudeProcessError.launchFailed("couldn't write the system prompt file")
        }
        lock.lock()
        scratchDirectory = dir
        lock.unlock()
        return file
    }

    private func removeScratch() {
        lock.lock()
        let dir = scratchDirectory
        scratchDirectory = nil
        lock.unlock()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            lock.unlock()
            return
        }
        buffer.append(chunk)
        var emitted: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            emitted.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        let cont = continuation
        lock.unlock()
        for line in emitted { cont?.yield(line) }
    }

    private func finish(status: Int32) {
        removeScratch()
        lock.lock()
        let trailing = buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        let stderr = stderrText
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let trailing { cont?.yield(trailing) }
        if status == 0 {
            cont?.finish()
        } else {
            cont?.finish(throwing: ClaudeProcessError.exited(code: status, stderr: stderr))
        }
    }
}
