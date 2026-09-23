import Foundation

// MARK: - Invocations

/// A fully-specified `claude` process launch. Pure data so argument
/// construction is unit-testable without spawning anything.
public struct ClaudeInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public enum ClaudeCommand {
    static let streamOutput = ["--output-format", "stream-json", "--verbose"]

    /// One headless turn on an existing session (documented resume path).
    public static func resume(
        executable: String, sessionId: String, prompt: String, cwd: String?
    ) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: ["-p", prompt, "--resume", sessionId] + streamOutput,
            workingDirectory: cwd
        )
    }

    /// Start a brand-new named session with its first prompt.
    public static func newSession(
        executable: String, name: String, prompt: String, cwd: String, model: String? = nil
    ) -> ClaudeInvocation {
        var args = ["-p", prompt, "--name", name] + streamOutput
        if let model, !model.isEmpty { args += ["--model", model] }
        return ClaudeInvocation(executable: executable, arguments: args, workingDirectory: cwd)
    }

    /// The long-lived relay session. It may only list and message sessions;
    /// `dontAsk` denies every tool that isn't pre-approved, and inbound
    /// replies are accepted so agents can answer it.
    public static func switchboard(
        executable: String, name: String, systemPrompt: String, model: String, cwd: String?
    ) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: [
                "-p",
                "--input-format", "stream-json",
            ] + streamOutput + [
                "--name", name,
                "--model", model,
                "--append-system-prompt", systemPrompt,
                "--allowedTools", "SendMessage,ListAgents",
                "--permission-mode", "dontAsk",
                "--settings", #"{"crossSessionInbound":"accept"}"#,
            ],
            workingDirectory: cwd
        )
    }

    /// One stenographer turn: ledger preloaded via the system prompt, no
    /// write tools. Resumes its own session when it has one.
    public static func stenographer(
        executable: String, prompt: String, systemPrompt: String, resumeSessionId: String?,
        model: String, cwd: String?
    ) -> ClaudeInvocation {
        var args = ["-p", prompt] + streamOutput + [
            "--model", model,
            "--append-system-prompt", systemPrompt,
            "--permission-mode", "dontAsk",
            "--disallowedTools", "Bash,Edit,Write,NotebookEdit,SendMessage",
        ]
        if let resumeSessionId { args += ["--resume", resumeSessionId] }
        return ClaudeInvocation(executable: executable, arguments: args, workingDirectory: cwd)
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
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrText = ""
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    /// stdout, one line per element. Finishes when the process exits; throws
    /// `ClaudeProcessError.exited` on a non-zero status.
    public let lines: AsyncThrowingStream<String, Error>

    public init(_ invocation: ClaudeInvocation) {
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
        do {
            try process.run()
        } catch {
            throw ClaudeProcessError.launchFailed(error.localizedDescription)
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

    /// Write one line to stdin (for `--input-format stream-json`).
    public func send(line: String) {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        stdinPipe.fileHandleForWriting.write(data)
    }

    public func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

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
