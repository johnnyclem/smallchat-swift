public struct ProviderManifest: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let tools: [ToolDefinition]
    public let transportType: TransportType
    public let endpoint: String?
    public let version: String?
    public let channel: ChannelInfo?
    public let description: String?
    public let compilerHints: ProviderCompilerHints?
    /// How to start or reach the upstream server (artifact format 1.0
    /// records it). When nil, `endpoint` (if any) is the server's URL.
    public let launch: LaunchSpec?

    public init(
        id: String,
        name: String,
        tools: [ToolDefinition],
        transportType: TransportType,
        endpoint: String? = nil,
        version: String? = nil,
        channel: ChannelInfo? = nil,
        description: String? = nil,
        compilerHints: ProviderCompilerHints? = nil,
        launch: LaunchSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.tools = tools
        self.transportType = transportType
        self.endpoint = endpoint
        self.version = version
        self.channel = channel
        self.description = description
        self.compilerHints = compilerHints
        self.launch = launch
    }

    public struct ChannelInfo: Sendable, Codable, Equatable {
        public let isChannel: Bool
        public let twoWay: Bool
        public let permissionRelay: Bool
        public let replyToolName: String?
        public let instructions: String?

        public init(
            isChannel: Bool,
            twoWay: Bool = false,
            permissionRelay: Bool = false,
            replyToolName: String? = nil,
            instructions: String? = nil
        ) {
            self.isChannel = isChannel
            self.twoWay = twoWay
            self.permissionRelay = permissionRelay
            self.replyToolName = replyToolName
            self.instructions = instructions
        }
    }
}

// MARK: - LaunchSpec

/// How to start or reach an upstream server: a stdio command (environment
/// variables by NAME only, never values) or a remote URL.
public struct LaunchSpec: Sendable, Codable, Equatable {
    /// `stdio`, `streamable-http`, `sse` or `http`.
    public var transport: String
    public var command: String?
    public var args: [String]?
    /// Names of the environment variables the server expects.
    public var env: [String]?
    public var url: String?

    public init(transport: String, command: String? = nil, args: [String]? = nil, env: [String]? = nil, url: String? = nil) {
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
    }

    /// A stdio launch spec.
    public static func stdio(command: String, args: [String] = [], env: [String] = []) -> LaunchSpec {
        LaunchSpec(transport: "stdio", command: command, args: args, env: env)
    }

    /// A remote launch spec (`streamable-http`, `sse` or `http`).
    public static func remote(_ transport: String, url: String) -> LaunchSpec {
        LaunchSpec(transport: transport, url: url)
    }

    public var isStdio: Bool { transport == "stdio" }

    /// The spec as artifact format 1.0 records it.
    public var jsonValue: [String: AnyCodableValue] {
        if isStdio {
            var seen = Set<String>()
            let names = (env ?? []).filter { seen.insert($0).inserted }
            return [
                "transport": .string(transport),
                "command": .string(command ?? ""),
                "args": .array((args ?? []).map { .string($0) }),
                "env": .array(names.map { .string($0) }),
            ]
        }
        return ["transport": .string(transport), "url": .string(url ?? "")]
    }
}
