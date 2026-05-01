import Foundation

// MARK: - Registry types
//
// Mirrors johnnyclem/smallchat#52 ("Add registry entry, bundle, and
// install schemas for MCP manifest compiler") in Swift form. These four
// types form the distribution layer:
//
//   RegistryEntry  -- a single installable provider, enriched with
//                     install metadata, env vars, configurable args,
//                     categories, and capability badges.
//   RegistryIndex  -- lightweight catalog for the website picker UI.
//   SmallChatBundle -- self-contained distributable: provider selections,
//                     compiled manifest, install instructions, and
//                     per-client wiring snippets.
//   InstallPlan    -- the ordered, reviewable list of steps that running
//                     a bundle would execute on the user's machine.

// MARK: - Install method

/// How a registry entry is installed.
public enum InstallMethod: Sendable, Codable, Equatable {
    case npm(packageName: String, command: String? = nil)
    case pip(packageName: String, command: String? = nil)
    case docker(image: String, args: [String] = [])
    case binary(downloadURL: String, sha256: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case kind
        case packageName
        case command
        case image
        case args
        case downloadURL
        case sha256
    }

    private enum Kind: String, Codable {
        case npm, pip, docker, binary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .npm:
            self = .npm(
                packageName: try c.decode(String.self, forKey: .packageName),
                command: try c.decodeIfPresent(String.self, forKey: .command)
            )
        case .pip:
            self = .pip(
                packageName: try c.decode(String.self, forKey: .packageName),
                command: try c.decodeIfPresent(String.self, forKey: .command)
            )
        case .docker:
            self = .docker(
                image: try c.decode(String.self, forKey: .image),
                args: try c.decodeIfPresent([String].self, forKey: .args) ?? []
            )
        case .binary:
            self = .binary(
                downloadURL: try c.decode(String.self, forKey: .downloadURL),
                sha256: try c.decodeIfPresent(String.self, forKey: .sha256)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .npm(let pkg, let cmd):
            try c.encode(Kind.npm, forKey: .kind)
            try c.encode(pkg, forKey: .packageName)
            try c.encodeIfPresent(cmd, forKey: .command)
        case .pip(let pkg, let cmd):
            try c.encode(Kind.pip, forKey: .kind)
            try c.encode(pkg, forKey: .packageName)
            try c.encodeIfPresent(cmd, forKey: .command)
        case .docker(let image, let args):
            try c.encode(Kind.docker, forKey: .kind)
            try c.encode(image, forKey: .image)
            if !args.isEmpty { try c.encode(args, forKey: .args) }
        case .binary(let url, let sha):
            try c.encode(Kind.binary, forKey: .kind)
            try c.encode(url, forKey: .downloadURL)
            try c.encodeIfPresent(sha, forKey: .sha256)
        }
    }
}

// MARK: - Env var spec

/// Specification of an environment variable a registry entry needs.
public struct RegistryEnvVar: Sendable, Codable, Equatable {
    public let name: String
    public let description: String?
    public let required: Bool
    public let defaultValue: String?
    /// Marks credentials so UIs can mask the value and avoid logging it.
    public let secret: Bool

    public init(
        name: String,
        description: String? = nil,
        required: Bool = false,
        defaultValue: String? = nil,
        secret: Bool = false
    ) {
        self.name = name
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.secret = secret
    }
}

// MARK: - Configurable arg

/// Specification of a CLI argument a registry entry accepts when launched.
public struct RegistryArg: Sendable, Codable, Equatable {
    public let name: String
    public let description: String?
    public let type: ArgType
    public let required: Bool
    public let defaultValue: AnyCodableValue?

    public enum ArgType: String, Sendable, Codable, Equatable {
        case string, number, bool, path
    }

    public init(
        name: String,
        description: String? = nil,
        type: ArgType,
        required: Bool = false,
        defaultValue: AnyCodableValue? = nil
    ) {
        self.name = name
        self.description = description
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case type
        case required
        case defaultValue = "default"
    }
}

// MARK: - RegistryEntry

/// An installable provider, enriched beyond `ProviderManifest` with the
/// metadata the registry website / install flow needs.
public struct RegistryEntry: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let homepage: String?
    public let license: String?
    public let categories: [String]
    public let badges: [String]
    public let installMethods: [InstallMethod]
    public let envVars: [RegistryEnvVar]
    public let args: [RegistryArg]
    /// Inline manifest. May be omitted by an index entry that only wants
    /// to advertise the entry's existence; full installs require it.
    public let manifest: ProviderManifest?

    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        homepage: String? = nil,
        license: String? = nil,
        categories: [String] = [],
        badges: [String] = [],
        installMethods: [InstallMethod] = [],
        envVars: [RegistryEnvVar] = [],
        args: [RegistryArg] = [],
        manifest: ProviderManifest? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.homepage = homepage
        self.license = license
        self.categories = categories
        self.badges = badges
        self.installMethods = installMethods
        self.envVars = envVars
        self.args = args
        self.manifest = manifest
    }
}

// MARK: - RegistryIndex

/// Lightweight catalog used by the picker UI. Each entry carries enough
/// metadata for browsing and search but omits the full provider manifest.
public struct RegistryIndex: Sendable, Codable, Equatable {
    public let version: String
    public let updatedAt: String
    public let entries: [RegistryIndexEntry]

    public init(version: String, updatedAt: String, entries: [RegistryIndexEntry]) {
        self.version = version
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public struct RegistryIndexEntry: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let categories: [String]
    public let badges: [String]
    public let toolCount: Int

    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        categories: [String] = [],
        badges: [String] = [],
        toolCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.categories = categories
        self.badges = badges
        self.toolCount = toolCount
    }
}

// MARK: - SmallChatBundle

/// A self-contained distributable bundle. Combines registry selections
/// with a compiled manifest and the per-client wiring snippets so a user
/// can install everything in one step.
public struct SmallChatBundle: Sendable, Codable, Equatable {
    public let name: String
    public let version: String
    public let description: String?
    public let entries: [RegistryEntry]
    public let compiledArtifactPath: String?
    public let targetClients: [TargetClient]

    public init(
        name: String,
        version: String,
        description: String? = nil,
        entries: [RegistryEntry],
        compiledArtifactPath: String? = nil,
        targetClients: [TargetClient] = []
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.entries = entries
        self.compiledArtifactPath = compiledArtifactPath
        self.targetClients = targetClients
    }

    public struct TargetClient: Sendable, Codable, Equatable {
        public let id: String           // e.g. "claude-code", "cursor", "vscode"
        public let displayName: String
        public let configPath: String   // path on disk where snippet is appended
        public let snippet: String      // JSON or TOML to write into configPath

        public init(id: String, displayName: String, configPath: String, snippet: String) {
            self.id = id
            self.displayName = displayName
            self.configPath = configPath
            self.snippet = snippet
        }
    }
}

// MARK: - InstallPlan

/// Ordered list of steps that running a bundle (or a single registry
/// entry) would execute on the user's machine. UIs and CLIs render this
/// for review before applying.
public struct InstallPlan: Sendable, Codable, Equatable {
    public let bundleName: String
    public let createdAt: String
    public let steps: [InstallStep]

    public init(bundleName: String, createdAt: String, steps: [InstallStep]) {
        self.bundleName = bundleName
        self.createdAt = createdAt
        self.steps = steps
    }

    /// Compute an InstallPlan for a single RegistryEntry. Picks the first
    /// install method (the entry author lists them in preference order)
    /// and adds steps for env-var prompts and target-client wiring.
    public static func plan(
        for entry: RegistryEntry,
        targetClients: [SmallChatBundle.TargetClient] = [],
        now: Date = Date()
    ) -> InstallPlan {
        var steps: [InstallStep] = []

        if let method = entry.installMethods.first {
            steps.append(InstallStep(
                kind: .install,
                summary: installSummary(method),
                detail: nil
            ))
        } else {
            steps.append(InstallStep(
                kind: .install,
                summary: "(no install method declared -- manual install required)",
                detail: nil
            ))
        }

        for env in entry.envVars where env.required {
            steps.append(InstallStep(
                kind: .envVarPrompt,
                summary: "Set \(env.name)",
                detail: env.description
            ))
        }

        for client in targetClients {
            steps.append(InstallStep(
                kind: .clientWiring,
                summary: "Append snippet to \(client.displayName) config (\(client.configPath))",
                detail: nil
            ))
        }

        steps.append(InstallStep(
            kind: .compile,
            summary: "Compile \(entry.id) manifest into the dispatch toolkit",
            detail: nil
        ))

        return InstallPlan(
            bundleName: entry.id,
            createdAt: ISO8601DateFormatter().string(from: now),
            steps: steps
        )
    }

    /// Compute an InstallPlan for a SmallChatBundle by concatenating the
    /// per-entry plans and de-duplicating the wiring steps.
    public static func plan(for bundle: SmallChatBundle, now: Date = Date()) -> InstallPlan {
        var steps: [InstallStep] = []
        for entry in bundle.entries {
            let entryPlan = InstallPlan.plan(for: entry, targetClients: [], now: now)
            steps.append(contentsOf: entryPlan.steps)
        }
        for client in bundle.targetClients {
            steps.append(InstallStep(
                kind: .clientWiring,
                summary: "Append bundle snippet to \(client.displayName) (\(client.configPath))",
                detail: nil
            ))
        }
        if let path = bundle.compiledArtifactPath {
            steps.append(InstallStep(
                kind: .compile,
                summary: "Use pre-compiled artifact at \(path)",
                detail: nil
            ))
        }
        return InstallPlan(
            bundleName: bundle.name,
            createdAt: ISO8601DateFormatter().string(from: now),
            steps: steps
        )
    }
}

public struct InstallStep: Sendable, Codable, Equatable {
    public let kind: Kind
    public let summary: String
    public let detail: String?

    public enum Kind: String, Sendable, Codable, Equatable {
        case install
        case envVarPrompt
        case clientWiring
        case compile
    }

    public init(kind: Kind, summary: String, detail: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

// MARK: - Helpers

private func installSummary(_ method: InstallMethod) -> String {
    switch method {
    case .npm(let pkg, let cmd):
        return cmd ?? "npm install \(pkg)"
    case .pip(let pkg, let cmd):
        return cmd ?? "pip install \(pkg)"
    case .docker(let image, _):
        return "docker pull \(image)"
    case .binary(let url, _):
        return "Download binary from \(url)"
    }
}
