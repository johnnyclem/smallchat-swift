import Foundation
import SmallChatCore

// MARK: - Filter Level

public enum RtkFilterLevel: String, Sendable, Codable {
    case `default`
    case aggressive
}

// MARK: - Config

/// Configuration for `RtkTransport` and `filterContentWithRtk`.
public struct RtkConfig: Sendable {
    /// Explicit path to the `rtk` binary. When `nil`, `$PATH` is searched.
    public var binaryPath: String?
    /// Minimum response size in bytes before filter mode activates (default 512).
    public var filterThresholdBytes: Int
    /// Compression aggressiveness passed to `rtk filter` (default `.default`).
    public var filterLevel: RtkFilterLevel
    /// Subprocess timeout in milliseconds (default 5000).
    public var timeoutMs: Int
    /// Master switch. When `false` the transport is a transparent pass-through (default `true`).
    public var enabled: Bool

    public init(
        binaryPath: String? = nil,
        filterThresholdBytes: Int = 512,
        filterLevel: RtkFilterLevel = .default,
        timeoutMs: Int = 5000,
        enabled: Bool = true
    ) {
        self.binaryPath = binaryPath
        self.filterThresholdBytes = filterThresholdBytes
        self.filterLevel = filterLevel
        self.timeoutMs = timeoutMs
        self.enabled = enabled
    }
}

// MARK: - Filter Result

/// Returned by `filterContentWithRtk` for callers that need standalone compression.
public struct RtkFilterResult: Sendable {
    public let compressed: Data
    public let savedPct: Double
    public let enabled: Bool
}

// MARK: - Binary Resolution State

private enum BinaryResolution: Sendable {
    case unresolved
    case found(String)
    case notFound
}

// MARK: - RtkTransport

/// Transport wrapper that applies RTK compression in two simultaneous modes:
///
/// **Prefix mode** — prepends `rtk ` to eligible shell commands in
/// `input.args["command"]` before the inner transport executes them.
///
/// **Filter mode** — pipes the inner transport's response body through
/// `rtk filter` when the body exceeds `filterThresholdBytes`.
///
/// Attach `RtkMetadata` to every response for observability regardless of
/// whether compression ran. When `enabled` is `false` the transport is a
/// transparent pass-through and no metadata is attached.
///
/// Mirrors the TypeScript `RtkTransport` class.
public actor RtkTransport: Transport {

    public nonisolated let id: String
    public nonisolated let transportType: TransportType?

    private let inner: any Transport
    private let config: RtkConfig
    private var binaryResolution: BinaryResolution = .unresolved

    private static var counter: Int = 0

    public init(wrapping inner: any Transport, config: RtkConfig = RtkConfig()) {
        RtkTransport.counter += 1
        self.id = "rtk-\(RtkTransport.counter)"
        self.transportType = inner.transportType
        self.inner = inner
        self.config = config
    }

    // MARK: - Transport protocol

    public nonisolated var isConnected: Bool {
        get async { await inner.isConnected }
    }

    public nonisolated func connect() async throws {
        try await inner.connect()
    }

    public nonisolated func disconnect() async throws {
        try await inner.disconnect()
    }

    public nonisolated func execute(input: TransportInput) async throws -> TransportOutput {
        try await _execute(input: input)
    }

    // MARK: - Core execution (actor-isolated)

    private func _execute(input: TransportInput) async throws -> TransportOutput {
        guard config.enabled else {
            return try await inner.execute(input: input)
        }

        let binary = await resolveBinary()

        // Prefix mode: rewrite eligible shell commands with `rtk ` prefix.
        let modifiedInput = applyPrefixMode(to: input, binaryPath: binary)

        let result: TransportOutput
        do {
            result = try await inner.execute(input: modifiedInput)
        } catch {
            return errorToTransportOutput(error)
        }

        // Filter mode: compress response body through rtk filter subprocess.
        return await applyFilterMode(to: result, binary: binary)
    }

    // MARK: - Binary resolution (cached)

    private func resolveBinary() async -> String? {
        switch binaryResolution {
        case .found(let path): return path
        case .notFound: return nil
        case .unresolved:
            if let explicit = config.binaryPath {
                if FileManager.default.isExecutableFile(atPath: explicit) {
                    binaryResolution = .found(explicit)
                    return explicit
                }
                binaryResolution = .notFound
                return nil
            }
            if let path = await rtkWhich("rtk") {
                binaryResolution = .found(path)
                return path
            }
            binaryResolution = .notFound
            return nil
        }
    }

    // MARK: - Prefix mode

    private func applyPrefixMode(to input: TransportInput, binaryPath: String?) -> TransportInput {
        guard let commandValue = input.args["command"],
              let command = commandValue.as(String.self) else {
            return input
        }
        // Avoid double-wrapping with the `rtk` keyword or the resolved binary path.
        if command.hasPrefix("rtk ") { return input }
        if let binaryPath, command.hasPrefix(binaryPath) { return input }
        guard isRtkEligibleCommand(command) else { return input }
        var modified = input
        modified.args["command"] = AnySendable("rtk \(command)")
        return modified
    }

    // MARK: - Filter mode

    private func applyFilterMode(to output: TransportOutput, binary: String?) async -> TransportOutput {
        guard !output.isError else { return attachNoopMetadata(to: output) }
        guard let body = output.body, !body.isEmpty else { return attachNoopMetadata(to: output) }
        let inputBytes = body.count
        guard inputBytes >= config.filterThresholdBytes, let binary else {
            return attachNoopMetadata(to: output)
        }
        do {
            let filtered = try await runRtkFilter(
                binary: binary,
                content: body,
                level: config.filterLevel,
                timeoutMs: config.timeoutMs
            )
            let outputBytes = filtered.count
            let savedPct = Double(inputBytes - outputBytes) / Double(inputBytes) * 100
            var result = output
            result.body = filtered
            result.rtkMetadata = RtkMetadata(
                enabled: true,
                inputBytes: inputBytes,
                outputBytes: outputBytes,
                savedPct: max(0, savedPct),
                mode: .filter
            )
            return result
        } catch {
            return attachNoopMetadata(to: output)
        }
    }

    private func attachNoopMetadata(to output: TransportOutput) -> TransportOutput {
        let inputBytes = output.body?.count ?? 0
        var result = output
        result.rtkMetadata = RtkMetadata(
            enabled: false,
            inputBytes: inputBytes,
            outputBytes: inputBytes,
            savedPct: 0,
            mode: .none
        )
        return result
    }
}

// MARK: - Eligible Command Prefixes

/// Commands whose output benefits from RTK compression.
///
/// Mirrors the `RTK_PREFIXES` constant in the TypeScript implementation.
let rtkPrefixes: [String] = [
    "git ", "cargo ", "npm ", "npx ", "pnpm ", "yarn ",
    "pytest", "python -m pytest", "go test", "go build",
    "grep ", "rg ", "find ", "ls ", "cat ", "eslint",
    "tsc", "docker ", "kubectl ", "aws ", "ruff ", "golangci-lint",
]

func isRtkEligibleCommand(_ command: String) -> Bool {
    rtkPrefixes.contains { command.hasPrefix($0) }
}

// MARK: - Factory

/// Wrap `inner` in an `RtkTransport` with optional configuration.
public func withRtk(_ inner: any Transport, config: RtkConfig = RtkConfig()) -> RtkTransport {
    RtkTransport(wrapping: inner, config: config)
}

// MARK: - Standalone Filter

/// Filter `content` through RTK without wrapping a full transport.
///
/// Exported for MCP server use. Respects `enabled`, threshold, binary
/// resolution, and `filterLevel`. Returns the original content unchanged
/// when RTK is unavailable or the content is below the threshold.
public func filterContentWithRtk(
    content: Data,
    config: RtkConfig = RtkConfig()
) async -> RtkFilterResult {
    guard config.enabled else {
        return RtkFilterResult(compressed: content, savedPct: 0, enabled: false)
    }
    let inputBytes = content.count
    guard inputBytes >= config.filterThresholdBytes else {
        return RtkFilterResult(compressed: content, savedPct: 0, enabled: false)
    }
    let binary: String?
    if let explicit = config.binaryPath {
        binary = FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
    } else {
        binary = await rtkWhich("rtk")
    }
    guard let binary else {
        return RtkFilterResult(compressed: content, savedPct: 0, enabled: false)
    }
    do {
        let compressed = try await runRtkFilter(
            binary: binary,
            content: content,
            level: config.filterLevel,
            timeoutMs: config.timeoutMs
        )
        let savedPct = Double(inputBytes - compressed.count) / Double(inputBytes) * 100
        return RtkFilterResult(compressed: compressed, savedPct: max(0, savedPct), enabled: true)
    } catch {
        return RtkFilterResult(compressed: content, savedPct: 0, enabled: false)
    }
}

// MARK: - Subprocess

/// Spawn `rtk filter [--aggressive]`, pipe `content` to stdin, collect stdout.
///
/// Rejects on non-zero exit code or `timeoutMs` expiry. Shared by
/// `RtkTransport` and `filterContentWithRtk`.
func runRtkFilter(
    binary: String,
    content: Data,
    level: RtkFilterLevel,
    timeoutMs: Int
) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = level == .aggressive ? ["filter", "--aggressive"] : ["filter"]

                let stdin = Pipe()
                let stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = Pipe()

                process.terminationHandler = { p in
                    if p.terminationStatus == 0 {
                        cont.resume(returning: stdout.fileHandleForReading.readDataToEndOfFile())
                    } else {
                        cont.resume(throwing: TransportError.unknown(
                            message: "rtk filter exited with code \(p.terminationStatus)"
                        ))
                    }
                }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(content)
                    stdin.fileHandleForWriting.closeFile()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            throw TransportError.timeout(durationMs: timeoutMs)
        }

        guard let data = try await group.next() else {
            throw TransportError.unknown(message: "rtk filter: empty task group")
        }
        group.cancelAll()
        return data
    }
}
