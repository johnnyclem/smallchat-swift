import Foundation
import SmallChatCore

// Spawns a subprocess, which iOS does not allow (no Foundation.Process).
#if os(macOS) || os(Linux)

/// MCP Stdio Transport — communicates with MCP servers via JSON-RPC over stdin/stdout.
///
/// Spawns a child process using `Foundation.Process`, sends JSON-RPC requests
/// to its stdin, and reads JSON-RPC responses from its stdout.
///
/// stdout is read on its own thread as raw bytes and split into lines on
/// `\n` before any UTF-8 decoding, so output split across pipe reads (inside a
/// multibyte character, too) arrives intact and in order. stderr is drained so
/// a chatty server cannot block on it. Every request is cancellable: a timeout
/// or a cancelled caller removes it, tells the server
/// (`notifications/cancelled`), and returns at once. A server that exits or
/// closes stdout fails every pending request.
///
/// Actor-isolated for state management of the process lifecycle and pending requests.
///
/// Mirrors the TypeScript `McpStdioTransport` class.
public actor MCPStdioTransport: Transport {

    /// The MCP protocol version this client asks for, and the versions it
    /// accepts from a server. Every one of them carries `tools/list` and
    /// `tools/call` the way this client uses them.
    public static let requestedProtocolVersion = "2025-11-25"
    public static let acceptedProtocolVersions: Set<String> = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    public nonisolated let id: String

    private let config: MCPStdioConfig
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineBuffer = Data()
    private var pendingRequests: [Int: CheckedContinuation<JsonRpcResponse, any Error>] = [:]
    private var initialized: Bool = false
    private var connecting: Task<Void, Error>?
    private var requestIdCounter: Int = 0
    /// Bumped for every spawned process, so output from an old one is ignored.
    private var generation: Int = 0
    private var stderrTail = Data()
    private let writeQueue = DispatchQueue(label: "smallchat.mcp-stdio.stdin")

    /// The protocol version the server agreed to, once connected.
    public private(set) var negotiatedProtocolVersion: String?

    private static let ids = TransportIDSequence(prefix: "mcp-stdio")

    public init(config: MCPStdioConfig) {
        self.id = Self.ids.next()
        self.config = config
    }

    // MARK: - Transport Protocol

    public nonisolated var isConnected: Bool {
        get async { await getInitialized() }
    }

    private func getInitialized() -> Bool { initialized }

    public nonisolated func connect() async throws {
        try await ensureInitialized()
    }

    public nonisolated func disconnect() async throws {
        await performDispose()
    }

    public nonisolated func execute(input: TransportInput) async throws -> TransportOutput {
        try await performExecute(input)
    }

    // MARK: - Tool Listing

    /// List available tools from the MCP server.
    public func listTools() async throws -> sending [[String: Any]] {
        try await ensureInitialized()
        let response = try await request(method: "tools/list", params: nil, timeout: 30)
        guard let result = response.result as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw TransportError.invalidResponse(message: "Invalid tools/list response")
        }
        return tools
    }

    // MARK: - Internal

    private func performExecute(_ input: TransportInput) async throws -> TransportOutput {
        try await ensureInitialized()

        var arguments: [String: Any] = [:]
        for (key, value) in input.args {
            arguments[key] = TransportSerialization.jsonCompatible(value.value)
        }
        let params: [String: Any] = ["name": input.toolName, "arguments": arguments]

        let response = try await request(method: "tools/call", params: params, timeout: input.timeout ?? 30)

        if let error = response.error {
            throw TransportError.fromJsonRpcError(code: error.code, message: error.message)
        }

        let resultData: Data
        if let result = response.result {
            resultData = try JSONSerialization.data(withJSONObject: result)
        } else {
            resultData = Data("null".utf8)
        }

        return TransportOutput(
            statusCode: 200,
            headers: [:],
            body: resultData,
            metadata: [:]
        )
    }

    /// Send a request and wait for its response, for at most `timeout`
    /// seconds (not positive: no deadline).
    private func request(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> JsonRpcResponse {
        let built = try buildRequest(method: method, params: params)
        let id = built.id, payload = built.encoded
        return try await withTimeout(seconds: timeout) {
            try await self.sendRequest(id: id, payload: payload)
        }
    }

    private func ensureInitialized() async throws {
        if initialized { return }
        if let connecting {
            return try await connecting.value
        }
        let task = Task { try await self.initialize() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func initialize() async throws {
        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        if let sandbox = config.containerSandbox, sandbox.enabled {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = buildDockerArgs()
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [config.command] + config.args
        }

        if let cwd = config.cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in config.env {
            env[key] = value
        }
        proc.environment = env

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        generation += 1
        let generation = self.generation
        lineBuffer = Data()
        stderrTail = Data()

        proc.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.connectionLost(generation: generation, reason: "MCP server exited with status \(status)") }
        }

        self.process = proc
        self.stdinHandle = stdin.fileHandleForWriting

        try proc.run()

        // stdout: raw byte chunks, in order, through one consumer.
        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        PipeIO.readUntilEOF(stdout.fileHandleForReading, onChunk: { chunkSink.yield($0) }, onEOF: { chunkSink.finish() })
        Task { [weak self] in
            for await chunk in chunks {
                await self?.ingest(chunk, generation: generation)
            }
            await self?.connectionLost(generation: generation, reason: "MCP server closed its output")
        }
        // stderr: drained, last few KB kept for error messages.
        PipeIO.readUntilEOF(stderr.fileHandleForReading, onChunk: { [weak self] chunk in
            Task { await self?.appendStderr(chunk, generation: generation) }
        }, onEOF: {})

        let response: JsonRpcResponse
        do {
            response = try await request(method: "initialize", params: [
                "protocolVersion": Self.requestedProtocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "smallchat",
                    "version": SmallChatVersion.current,
                ] as [String: Any],
            ], timeout: config.initTimeout)
        } catch {
            performDispose()
            throw error
        }

        if let error = response.error {
            performDispose()
            throw TransportError.connectionFailed(
                message: "MCP initialize failed: \(error.message)"
            )
        }
        let version = (response.result as? [String: Any])?["protocolVersion"] as? String
        guard let version, Self.acceptedProtocolVersions.contains(version) else {
            performDispose()
            throw TransportError.connectionFailed(
                message: "MCP server answered initialize with unsupported protocol version \(version ?? "(none)")"
            )
        }
        negotiatedProtocolVersion = version

        writeLine(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
    }

    private func sendRequest(id: Int, payload: Data) async throws -> JsonRpcResponse {
        guard stdinHandle != nil, process?.isRunning == true else {
            throw TransportError.connectionFailed(message: "MCP server stdin not writable\(stderrSuffix())")
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingRequests[id] = continuation
                self.write(payload, forRequest: id)
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// Fail a pending request because its caller gave up (timeout or task
    /// cancellation), and tell the server.
    private func cancelRequest(_ id: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        writeLine([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": id, "reason": "request timed out or was cancelled"] as [String: Any],
        ])
    }

    private func failRequest(_ id: Int, _ error: Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - stdin

    /// Queue `payload` + newline for stdin. Writes happen in order on a
    /// background queue, so a server that is slow to read cannot block the
    /// actor; a failed write fails `requestId`'s request.
    private func write(_ payload: Data, forRequest requestId: Int?) {
        guard let stdinHandle else {
            if let requestId { failRequest(requestId, TransportError.connectionFailed(message: "MCP server stdin not writable")) }
            return
        }
        var newlineTerminated = payload
        newlineTerminated.append(0x0A)
        let line = newlineTerminated
        let handle = UncheckedSendableBox(stdinHandle)
        let generation = self.generation
        writeQueue.async { [weak self] in
            let ok = PipeIO.writeAll(line, to: handle.value)
            if !ok {
                Task { await self?.connectionLost(generation: generation, reason: "MCP server stopped reading its input") }
            }
        }
    }

    private func writeLine(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        write(data, forRequest: nil)
    }

    // MARK: - stdout

    private func ingest(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        lineBuffer.append(chunk)
        var lineStart = lineBuffer.startIndex
        while let newline = lineBuffer[lineStart...].firstIndex(of: 0x0A) {
            processLine(lineBuffer[lineStart..<newline])
            lineStart = lineBuffer.index(after: newline)
        }
        if lineStart != lineBuffer.startIndex {
            lineBuffer = Data(lineBuffer[lineStart...])
        }
    }

    private func processLine(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["jsonrpc"] as? String == "2.0" else {
            return
        }

        // A request from the server (it has both a method and an id).
        if let method = json["method"] as? String {
            if let requestId = json["id"] {
                answerServerRequest(id: requestId, method: method)
            }
            return // notifications are ignored
        }

        guard let id = json["id"] as? Int else { return }

        let response = JsonRpcResponse(
            id: id,
            result: json["result"],
            error: (json["error"] as? [String: Any]).flatMap { errDict in
                guard let code = errDict["code"] as? Int,
                      let message = errDict["message"] as? String else { return nil }
                return JsonRpcResponseError(code: code, message: message, data: errDict["data"])
            }
        )

        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: response)
        }
    }

    /// Answer server-to-client requests: `ping` succeeds, anything else is
    /// not supported by this client.
    private func answerServerRequest(id: Any, method: String) {
        if method == "ping" {
            writeLine(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        } else {
            writeLine([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not found: \(method)"] as [String: Any],
            ])
        }
    }

    private func appendStderr(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        stderrTail.append(chunk)
        if stderrTail.count > 4096 {
            stderrTail = Data(stderrTail.suffix(4096))
        }
    }

    private func stderrSuffix() -> String {
        let text = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " (stderr: \(text))"
    }

    // MARK: - Lifecycle

    /// The process exited, closed stdout, or stopped reading stdin: fail
    /// everything in flight and forget the process.
    private func connectionLost(generation: Int, reason: String) {
        guard generation == self.generation, process != nil else { return }
        let error = TransportError.connectionFailed(message: reason + stderrSuffix())
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        if let process { PipeIO.stop(process) }
        initialized = false
        process = nil
        stdinHandle = nil
    }

    private func performDispose() {
        generation += 1
        if let stdinHandle {
            let handle = UncheckedSendableBox(stdinHandle)
            writeQueue.async { try? handle.value.close() }
        }
        if let process {
            PipeIO.stop(process, grace: 3)
        }

        // Reject all pending requests
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: TransportError.disposed)
        }
        initialized = false
        negotiatedProtocolVersion = nil
        process = nil
        stdinHandle = nil
    }

    // MARK: - Request Building

    private struct BuiltRequest {
        let id: Int
        let encoded: Data
    }

    private func buildRequest(method: String, params: [String: Any]? = nil) throws -> BuiltRequest {
        requestIdCounter += 1
        let id = requestIdCounter

        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            dict["params"] = params
        }

        guard JSONSerialization.isValidJSONObject(dict) else {
            throw TransportError.invalidResponse(message: "\(method) arguments are not representable as JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return BuiltRequest(id: id, encoded: data)
    }

    private func buildDockerArgs() -> [String] {
        guard let sandbox = config.containerSandbox else { return [config.command] + config.args }

        var args = ["docker", "run", "--rm", "-i"]
        args.append("--cap-drop=ALL")
        args.append("--security-opt=no-new-privileges")
        args.append("--network=\(sandbox.network ?? "none")")

        if let mem = sandbox.memoryLimit {
            args.append("--memory=\(mem)")
        }
        if let cpu = sandbox.cpuLimit {
            args.append("--cpus=\(cpu)")
        }
        for mount in sandbox.readOnlyMounts ?? [] {
            args.append(contentsOf: ["-v", "\(mount):\(mount):ro"])
        }
        for (key, value) in config.env {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if let extra = sandbox.extraArgs {
            args.append(contentsOf: extra)
        }

        args.append(sandbox.image)
        args.append(config.command)
        args.append(contentsOf: config.args)

        return args
    }
}
#endif // os(macOS) || os(Linux)

// MARK: - JSON-RPC Helper Types

// JSON-RPC response types are @unchecked Sendable because they hold
// JSON-compatible `Any` values that are inherently safe.

struct JsonRpcResponse: @unchecked Sendable {
    let id: Int
    let result: Any?
    let error: JsonRpcResponseError?

    init(id: Int, result: Any?, error: JsonRpcResponseError?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

struct JsonRpcResponseError: @unchecked Sendable {
    let code: Int
    let message: String
    let data: Any?

    init(code: Int, message: String, data: Any? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}
