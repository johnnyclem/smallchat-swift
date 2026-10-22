import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a stenographer is launched: the TypeScript server, through npm.
public struct StenographerLaunch: Sendable, Equatable {
    /// The log file or directory to tail or watch
    public var logPath: String
    /// The state database (default `./stenographer.db`)
    public var statePath: String?
    /// `live`, `catchup`, `watch` or `daemon` (REST needs daemon, or `restPort`)
    public var mode: String
    public var restPort: Int
    public var adapter: String?
    /// `off`, `shadow` or `deliver`
    public var objections: String?
    /// smallchat channel bridge URLs objections are pushed to
    public var objectionChannels: [String]
    /// `off`, `d1`, `jev` or a URL (see stenographer's --decision-model)
    public var decisionModel: String?
    /// `agent` or `operator`
    public var profile: String?
    /// The `@stenographer/core` version to run (`latest` by default)
    public var packageVersion: String?
    /// Extra arguments passed through verbatim
    public var extraArgs: [String]
    /// `npx` executable (default: found on the PATH)
    public var npx: String

    public init(logPath: String, statePath: String? = nil, mode: String = "daemon", restPort: Int = 8787, adapter: String? = nil,
                objections: String? = nil, objectionChannels: [String] = [], decisionModel: String? = nil, profile: String? = nil,
                packageVersion: String? = nil, extraArgs: [String] = [], npx: String = "npx") {
        self.logPath = logPath
        self.statePath = statePath
        self.mode = mode
        self.restPort = restPort
        self.adapter = adapter
        self.objections = objections
        self.objectionChannels = objectionChannels
        self.decisionModel = decisionModel
        self.profile = profile
        self.packageVersion = packageVersion
        self.extraArgs = extraArgs
        self.npx = npx
    }

    /// The command line, `npx` first: `npx -y @stenographer/core[@version] start <log> [state] --mode … --rest-port …`.
    public var arguments: [String] {
        var args = [npx, "-y", "@stenographer/core" + (packageVersion.map { "@\($0)" } ?? ""), "start", logPath]
        if let statePath { args.append(statePath) }
        args += ["--mode", mode, "--rest-port", String(restPort)]
        if let adapter { args += ["--adapter", adapter] }
        if let objections { args += ["--objections", objections] }
        for url in objectionChannels { args += ["--objection-channel", url] }
        if let decisionModel { args += ["--decision-model", decisionModel] }
        if let profile { args += ["--profile", profile] }
        return args + extraArgs
    }

    /// The command as a shell line a person can copy (secrets come from the environment, never the line).
    public var shellCommand: String {
        arguments.map { arg in arg.contains(" ") ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'" : arg }.joined(separator: " ")
    }
}

#if os(macOS) || os(Linux)
/// A stenographer this process launched (`npx -y @stenographer/core start …`),
/// with its REST client. Secrets (`STENOGRAPHER_REST_TOKEN`,
/// `STENOGRAPHER_NOTARY_SECRET`, `SMALLCHAT_CHANNEL_SECRET`, a model key) go
/// in through `environment`, never on the command line.
public final class StenographerProcess: @unchecked Sendable {
    public let launch: StenographerLaunch
    public let client: StenographerClient
    private let process: Process
    private let lock = NSLock()
    private var recent: [String] = []

    /// Start stenographer and wait until `GET /status` answers (or `readyTimeout` passes, when the process is stopped and the error says what it printed last).
    public static func start(
        _ launch: StenographerLaunch,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        readyTimeout: TimeInterval = 60,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> StenographerProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = launch.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        let token = environment["STENOGRAPHER_REST_TOKEN"] ?? ProcessInfo.processInfo.environment["STENOGRAPHER_REST_TOKEN"]
        let client = try StenographerClient(
            baseURL: URL(string: "http://127.0.0.1:\(launch.restPort)")!,
            token: token,
            notarySecret: environment["STENOGRAPHER_NOTARY_SECRET"] ?? ProcessInfo.processInfo.environment["STENOGRAPHER_NOTARY_SECRET"]
        )
        let handle = StenographerProcess(launch: launch, client: client, process: process)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                handle.remember(String(line))
                log?(String(line))
            }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if !process.isRunning {
                throw StenographerClientError(kind: .network, message: "stenographer exited (status \(process.terminationStatus)) before it was ready:\n\(handle.recentOutput.joined(separator: "\n"))")
            }
            if (try? await client.status()) != nil { return handle }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        handle.stop()
        throw StenographerClientError(kind: .network, message: "stenographer did not answer at \(client.baseURL.absoluteString)/status within \(Int(readyTimeout)) s:\n\(handle.recentOutput.joined(separator: "\n"))")
    }

    private init(launch: StenographerLaunch, client: StenographerClient, process: Process) {
        self.launch = launch
        self.client = client
        self.process = process
    }

    public var isRunning: Bool { process.isRunning }

    /// The last 20 lines the process printed.
    public var recentOutput: [String] { lock.withLock { recent } }

    private func remember(_ line: String) {
        lock.withLock {
            recent.append(line)
            if recent.count > 20 { recent.removeFirst() }
        }
    }

    /// SIGTERM, then wait up to `grace` seconds before SIGKILL.
    public func stop(grace: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
#endif
