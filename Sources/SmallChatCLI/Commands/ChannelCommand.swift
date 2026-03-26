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

    @Flag(help: "Enable HTTP bridge for inbound webhooks")
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

        let config = ChannelServerConfig(
            channelName: name,
            twoWay: twoWay,
            replyToolName: replyTool,
            permissionRelay: permissionRelay,
            instructions: instructions,
            httpBridge: httpBridge,
            httpBridgePort: httpBridgePort,
            httpBridgeHost: httpBridgeHost,
            senderAllowlist: parsedAllowlist
        )

        let server = ChannelServer(config: config)
        await server.start()

        FileHandle.standardError.write(Data(
            ("[channel] \(name) channel server started (stdio)\n" +
             "  Two-way: \(twoWay ? "yes" : "no")\n" +
             "  Permission relay: \(permissionRelay ? "yes" : "no")\n" +
             "  HTTP bridge: \(httpBridge ? "http://\(httpBridgeHost):\(httpBridgePort)" : "disabled")\n").utf8
        ))

        // Forward outbound messages to stdout
        let outboundTask = Task {
            for await message in await server.outboundMessages {
                print(message)
                fflush(stdout)
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

        // Read stdin lines and feed them to the server
        let stdinTask = Task {
            while let line = readLine(strippingNewline: false) {
                await server.handleLine(line)
            }
        }

        // Wait for stdin EOF or SIGINT
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGINT, SIG_IGN)
            let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigSource.setEventHandler {
                sigSource.cancel()
                continuation.resume()
            }
            sigSource.resume()
        }

        stdinTask.cancel()
        outboundTask.cancel()
        eventsTask.cancel()
        await server.shutdown()
    }
}
