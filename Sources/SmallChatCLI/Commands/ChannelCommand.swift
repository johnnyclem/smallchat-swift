import ArgumentParser
import Foundation
import SmallChat

struct ChannelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "channel",
        abstract: "Run a stdio MCP channel server"
    )

    @Option(name: .shortAndLong, help: "Channel name/identifier")
    var name: String

    @Flag(help: "Enable two-way mode with reply tool")
    var twoWay: Bool = false

    @Option(help: "Reply tool name")
    var replyTool: String = "reply"

    @Flag(help: "Enable permission relay")
    var permissionRelay: Bool = false

    @Option(help: "Channel instructions for the LLM")
    var instructions: String?

    @Flag(help: "Enable the HTTP bridge for inbound events (POST /event; needs SMALLCHAT_CHANNEL_SECRET)")
    var httpBridge: Bool = false

    @Option(help: "HTTP bridge port")
    var httpBridgePort: Int = 3002

    @Option(help: "HTTP bridge host")
    var httpBridgeHost: String = "127.0.0.1"

    @Option(help: "Comma-separated sender allowlist")
    var senderAllowlist: String?

    func run() async throws {
        // Validate: permission relay needs sender gating
        if permissionRelay && senderAllowlist == nil {
            FileHandle.standardError.write(Data(
                ("Warning: --permission-relay is enabled but no sender allowlist is configured.\n" +
                 "Permission relay will reject all verdicts until sender gating is set up.\n\n").utf8
            ))
        }

        let parsedAllowlist = senderAllowlist?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // The bridge's shared secret is mandatory (suite contract).
        var bridgeSecret: String?
        if httpBridge {
            guard let secret = ProcessInfo.processInfo.environment["SMALLCHAT_CHANNEL_SECRET"], !secret.isEmpty else {
                throw ValidationError("--http-bridge needs a shared secret in SMALLCHAT_CHANNEL_SECRET")
            }
            bridgeSecret = secret
        }

        let config = ChannelServerConfig(
            channelName: name,
            twoWay: twoWay,
            replyToolName: replyTool,
            permissionRelay: permissionRelay,
            instructions: instructions,
            httpBridge: httpBridge,
            httpBridgePort: httpBridgePort,
            httpBridgeHost: httpBridgeHost,
            httpBridgeSecret: bridgeSecret,
            senderAllowlist: parsedAllowlist
        )

        let server = ChannelServer(config: config)
        await server.start()
        let bridgePort = try await server.startHTTPBridge()

        FileHandle.standardError.write(Data(
            ("[channel] \(name) channel server started (stdio)\n" +
             "  Two-way: \(twoWay ? "yes" : "no")\n" +
             "  Permission relay: \(permissionRelay ? "yes" : "no")\n" +
             "  HTTP bridge: \(bridgePort.map { "http://\(httpBridgeHost):\($0) (POST /event, GET /health)" } ?? "disabled")\n").utf8
        ))

        // Forward outbound messages to stdout
        let outboundTask = Task {
            for await message in await server.outboundMessages {
                print(message)
                fflush(nil)  // all streams; referencing the global `stdout` isn't concurrency-safe
            }
        }

        // Log server events to stderr
        let eventsTask = Task {
            for await event in await server.events {
                switch event {
                case .reply(let channel, let message, let timestamp):
                    FileHandle.standardError.write(Data(
                        "[channel] [\(timestamp)] reply on \(channel): \(message)\n".utf8
                    ))
                case .permissionRequestReceived(let request):
                    FileHandle.standardError.write(Data(
                        "[channel] permission request \(request.requestId): \(request.description)\n".utf8
                    ))
                case .permissionVerdictSent(let verdict):
                    FileHandle.standardError.write(Data(
                        "[channel] permission verdict \(verdict.requestId): \(verdict.behavior.rawValue)\n".utf8
                    ))
                case .senderRejected(let sender):
                    FileHandle.standardError.write(Data(
                        "[channel] sender rejected: \(sender ?? "unknown")\n".utf8
                    ))
                case .payloadTooLarge(let size, let limit):
                    FileHandle.standardError.write(Data(
                        "[channel] payload too large: \(size) bytes (limit: \(limit))\n".utf8
                    ))
                default:
                    break
                }
            }
        }

        // Stop on stdin EOF (the host closed the channel) or SIGINT.
        let (stopRequests, requestStop) = AsyncStream<Void>.makeStream()

        // stdin is read on its own thread: readLine blocks, and must not
        // hold a cooperative-pool thread.
        let (lines, lineSink) = AsyncStream<String>.makeStream()
        let reader = Thread {
            while let line = readLine(strippingNewline: false) {
                lineSink.yield(line)
            }
            lineSink.finish()
        }
        reader.start()
        let stdinTask = Task {
            for await line in lines {
                await server.handleLine(line)
            }
            requestStop.yield(())
        }

        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSource.setEventHandler { requestStop.yield(()) }
        sigSource.resume()

        for await _ in stopRequests { break }
        sigSource.cancel()

        stdinTask.cancel()
        await server.shutdown()
        // shutdown finished the streams: let the last replies reach stdout.
        await outboundTask.value
        eventsTask.cancel()
    }
}
