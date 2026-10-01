import Foundation

// MARK: - Artifact format 1.0 (spec/artifact in @smallchat/core)

/// The only artifact format version this release reads and writes.
public let ARTIFACT_FORMAT_VERSION = "1.0"

/// Domain-separation prefix of the artifact content hash.
public let artifactHashDomain = "smallchat.artifact.v1"

/// A file that is not a valid, intact 1.0 artifact.
public struct ArtifactFormatError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// An artifact from an older (or newer) format: recompile it.
public struct ArtifactVersionError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// An embedder that does not match an artifact's fingerprint.
public struct EmbedderMismatchError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// One upstream server.
public struct ArtifactProvider: Sendable, Equatable {
    /// Provider id; never contains `/`
    public let id: String
    public let name: String
    /// `mcp`, `rest`, `local` or `grpc`
    public let transportType: String
    public let version: String?
    /// How to start or reach the upstream server, when known
    public let launch: LaunchSpec?
    /// Provider-level compiler hints, passed through unchanged
    public let compilerHints: [String: AnyCodableValue]?
}

/// One upstream tool, keyed in the artifact by its canonical id.
public struct ArtifactTool: Sendable, Equatable {
    /// Canonical tool id `<providerId>/<name>`
    public let id: String
    public let providerId: String
    /// Upstream tool name, verbatim
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: [String: AnyCodableValue]
    public let outputSchema: [String: AnyCodableValue]?
    public let annotations: ToolAnnotations?
    public let transportType: String
    /// Canonical of the tool's primary selector (a key of `selectors`)
    public let selector: String
    /// Tool-level compiler hints, passed through unchanged
    public let compilerHints: [String: AnyCodableValue]?
}

/// A dispatchable selector: one embedding pointing at exactly one tool.
public struct ArtifactSelector: Sendable, Equatable {
    public let canonical: String
    /// The tool this selector dispatches to
    public let toolId: String
    /// `tool` for a tool's primary selector, `alias` for a compiler-hint alias
    public let kind: String
    /// Embedding produced by the artifact's embedder (`embedder.dims` entries)
    public let vector: [Float]
}

/// A compiled toolkit artifact, format 1.0, validated (spec/artifact
/// rules 1-4). `json` is the document; the typed properties are views of it.
///
/// Rule 5 -- the embedder used with the artifact has its fingerprint --
/// is checked by `assertEmbedder(_:)`, which every load path calls.
public struct ArtifactV1: Sendable {
    /// The whole document, as read or built.
    public let json: [String: AnyCodableValue]
    /// The embedder every selector vector was produced with.
    public let embedder: EmbedderFingerprint
    public let providers: [String: ArtifactProvider]
    public let tools: [String: ArtifactTool]
    public let selectors: [String: ArtifactSelector]
    public let collisions: [SelectorCollision]
    public let duplicates: [DuplicateToolPair]
    /// `sha256hex(UTF8("smallchat.artifact.v1") || 0x00 || UTF8(JCS(artifact without contentHash)))`
    public let contentHash: String

    /// Tool ids, sorted.
    public var toolIds: [String] { tools.keys.sorted() }

    /// The selectors of a tool: its primary selector first, then its aliases (sorted).
    public func selectors(of toolId: String) -> [ArtifactSelector] {
        guard let tool = tools[toolId] else { return [] }
        let aliases = selectors.values.filter { $0.toolId == toolId && $0.kind == "alias" }.sorted { $0.canonical < $1.canonical }
        return (selectors[tool.selector].map { [$0] } ?? []) + aliases
    }

    // MARK: Reading

    /// Read and validate an artifact file (see `validate(_:source:)`).
    public static func read(contentsOf url: URL) throws -> ArtifactV1 {
        try parse(Data(contentsOf: url), source: url.path)
    }

    /// Parse and validate artifact JSON (see `validate(_:source:)`).
    public static func parse(_ data: Data, source: String = "artifact") throws -> ArtifactV1 {
        let value: AnyCodableValue
        do {
            value = try parseJSON(data)
        } catch {
            throw ArtifactFormatError("\(source) is not valid JSON: \(error)")
        }
        return try validate(value, source: source)
    }

    /// Validate an in-memory value as a 1.0 artifact: format version, the
    /// JSON Schema, internal consistency (ids, selector ownership, vector
    /// dimensions, stats) and the content hash. Throws
    /// `ArtifactVersionError` (older or newer format) or `ArtifactFormatError`.
    public static func validate(_ value: AnyCodableValue, source: String = "artifact") throws -> ArtifactV1 {
        guard case .dict(let object) = value else {
            throw ArtifactFormatError("\(source) is not a smallchat artifact (expected a JSON object)")
        }

        // Rule 1: format version
        guard let formatVersion = object["formatVersion"] else {
            if object["version"] != nil || object["dispatchTables"] != nil {
                let version = object["version"]?.stringValue.map { " (version \($0))" } ?? ""
                throw ArtifactVersionError(
                    "\(source) is a pre-1.0 smallchat artifact\(version), which does not record its embedder or tool schemas; "
                    + "recompile with smallchat 1.0 (`smallchat compile --source <manifests>`)."
                )
            }
            throw ArtifactFormatError("\(source) is not a smallchat artifact (missing formatVersion)")
        }
        guard formatVersion == .string(ARTIFACT_FORMAT_VERSION) else {
            let shown = (try? canonicalJSON(formatVersion)) ?? "?"
            throw ArtifactVersionError(
                "\(source) has formatVersion \(shown); this smallchat reads formatVersion \"\(ARTIFACT_FORMAT_VERSION)\". "
                + "Recompile it with this version of smallchat."
            )
        }

        // Rule 2: schema
        let errors = schemaValidator.validate(value)
        if !errors.isEmpty {
            let details = errors.prefix(5).map { "  \($0.path.isEmpty ? "/" : $0.path) \($0.message)" }.joined(separator: "\n")
            throw ArtifactFormatError("\(source) does not match the artifact 1.0 schema:\n\(details)")
        }

        let artifact = try decode(object, source: source)

        // Rule 3: consistency
        try checkConsistency(artifact, object: object, source: source)

        // Rule 4: content hash
        let expected: String
        do {
            expected = try computeContentHash(object)
        } catch {
            throw ArtifactFormatError("\(source) cannot be hashed: \(error)")
        }
        guard artifact.contentHash == expected else {
            throw ArtifactFormatError(
                "\(source) failed its content-hash check (recorded \(artifact.contentHash), computed \(expected)); "
                + "it was modified after compilation or is corrupt. Recompile it."
            )
        }
        return artifact
    }

    /// The content hash of an artifact object (its `contentHash` member is ignored).
    public static func computeContentHash(_ object: [String: AnyCodableValue]) throws -> String {
        var body = object
        body.removeValue(forKey: "contentHash")
        return try domainDigest(artifactHashDomain, canonicalJSON(.dict(body)))
    }

    // MARK: Embedder identity (rule 5)

    /// Throw `EmbedderMismatchError` unless `embedder` declares exactly this
    /// artifact's fingerprint (all seven fields) and dimensions. Vectors from
    /// different embedders are not comparable, so a mismatch is never a warning.
    public func assertEmbedder(_ embedder: any Embedder, source: String = "artifact") throws {
        guard let actual = embedder.fingerprint else {
            throw EmbedderMismatchError(
                "\(source) was compiled with \(self.embedder.summary), but the supplied embedder declares no "
                + "fingerprint, so it cannot be verified to produce comparable vectors."
            )
        }
        guard actual == self.embedder, embedder.dimensions == self.embedder.dims else {
            throw EmbedderMismatchError(
                "\(source) was compiled with \(self.embedder.summary), but the embedder in use is \(actual.summary). "
                + "Vectors from different embedders are not comparable: use the embedder the artifact was compiled with, "
                + "or recompile the artifact."
            )
        }
    }

    // MARK: Writing

    /// The artifact's on-disk JSON: indented, members sorted, trailing newline.
    public func serialized() throws -> Data {
        Data(try prettyJSON(.dict(json)).utf8)
    }

    /// Write the artifact to `url`.
    public func write(to url: URL) throws {
        try serialized().write(to: url, options: .atomic)
    }

    // MARK: - Internals

    private static let schemaValidator: JSONSchemaValidator = {
        // The generated schema is a constant; it compiling is covered by tests.
        try! JSONSchemaValidator(json: artifactV1SchemaJSON)
    }()

    private static func decode(_ object: [String: AnyCodableValue], source: String) throws -> ArtifactV1 {
        func dict(_ v: AnyCodableValue?) -> [String: AnyCodableValue] {
            if case .dict(let d)? = v { return d }
            return [:]
        }
        func array(_ v: AnyCodableValue?) -> [AnyCodableValue] {
            if case .array(let a)? = v { return a }
            return []
        }
        func optionalDict(_ v: AnyCodableValue?) -> [String: AnyCodableValue]? {
            if case .dict(let d)? = v { return d }
            return nil
        }

        let e = dict(object["embedder"])
        let embedder = EmbedderFingerprint(
            kind: e["kind"]?.stringValue ?? "",
            model: e["model"]?.stringValue ?? "",
            modelSha256: e["modelSha256"]?.stringValue,
            dims: Int(e["dims"]?.numberValue ?? 0),
            maxLength: e["maxLength"]?.numberValue.map { Int($0) },
            pooling: e["pooling"]?.stringValue ?? "",
            normalize: e["normalize"]?.boolValue ?? false
        )

        var providers: [String: ArtifactProvider] = [:]
        for (key, value) in dict(object["providers"]) {
            let p = dict(value)
            var launch: LaunchSpec?
            if let l = optionalDict(p["launch"]) {
                launch = LaunchSpec(
                    transport: l["transport"]?.stringValue ?? "",
                    command: l["command"]?.stringValue,
                    args: l["args"]?.stringArray,
                    env: l["env"]?.stringArray,
                    url: l["url"]?.stringValue
                )
            }
            providers[key] = ArtifactProvider(
                id: p["id"]?.stringValue ?? "",
                name: p["name"]?.stringValue ?? "",
                transportType: p["transportType"]?.stringValue ?? "",
                version: p["version"]?.stringValue,
                launch: launch,
                compilerHints: optionalDict(p["compilerHints"])
            )
        }

        var tools: [String: ArtifactTool] = [:]
        for (key, value) in dict(object["tools"]) {
            let t = dict(value)
            var annotations: ToolAnnotations?
            if let a = optionalDict(t["annotations"]) {
                annotations = ToolAnnotations(
                    title: a["title"]?.stringValue,
                    readOnlyHint: a["readOnlyHint"]?.boolValue,
                    destructiveHint: a["destructiveHint"]?.boolValue,
                    idempotentHint: a["idempotentHint"]?.boolValue,
                    openWorldHint: a["openWorldHint"]?.boolValue
                )
            }
            tools[key] = ArtifactTool(
                id: t["id"]?.stringValue ?? "",
                providerId: t["providerId"]?.stringValue ?? "",
                name: t["name"]?.stringValue ?? "",
                title: t["title"]?.stringValue,
                description: t["description"]?.stringValue ?? "",
                inputSchema: dict(t["inputSchema"]),
                outputSchema: optionalDict(t["outputSchema"]),
                annotations: annotations,
                transportType: t["transportType"]?.stringValue ?? "",
                selector: t["selector"]?.stringValue ?? "",
                compilerHints: optionalDict(t["compilerHints"])
            )
        }

        var selectors: [String: ArtifactSelector] = [:]
        for (key, value) in dict(object["selectors"]) {
            let s = dict(value)
            selectors[key] = ArtifactSelector(
                canonical: s["canonical"]?.stringValue ?? "",
                toolId: s["toolId"]?.stringValue ?? "",
                kind: s["kind"]?.stringValue ?? "",
                vector: array(s["vector"]).map { Float($0.numberValue ?? 0) }
            )
        }

        let collisions = array(object["collisions"]).map { value -> SelectorCollision in
            let c = dict(value)
            return SelectorCollision(
                selectorA: c["selectorA"]?.stringValue ?? "",
                selectorB: c["selectorB"]?.stringValue ?? "",
                similarity: c["similarity"]?.numberValue ?? 0,
                hint: c["hint"]?.stringValue ?? ""
            )
        }
        let duplicates = array(object["duplicates"]).map { value -> DuplicateToolPair in
            let d = dict(value)
            return DuplicateToolPair(
                toolA: d["toolA"]?.stringValue ?? "",
                toolB: d["toolB"]?.stringValue ?? "",
                selectorA: d["selectorA"]?.stringValue ?? "",
                selectorB: d["selectorB"]?.stringValue ?? "",
                similarity: d["similarity"]?.numberValue ?? 0
            )
        }

        return ArtifactV1(
            json: object,
            embedder: embedder,
            providers: providers,
            tools: tools,
            selectors: selectors,
            collisions: collisions,
            duplicates: duplicates,
            contentHash: object["contentHash"]?.stringValue ?? ""
        )
    }

    private static func checkConsistency(_ artifact: ArtifactV1, object: [String: AnyCodableValue], source: String) throws {
        func fail(_ message: String) -> ArtifactFormatError {
            ArtifactFormatError("\(source) is inconsistent: \(message)")
        }

        for key in artifact.providers.keys.sorted() {
            let provider = artifact.providers[key]!
            if provider.id != key { throw fail("provider key \"\(key)\" holds provider id \"\(provider.id)\"") }
        }

        for key in artifact.tools.keys.sorted() {
            let tool = artifact.tools[key]!
            if tool.id != key { throw fail("tool key \"\(key)\" holds tool id \"\(tool.id)\"") }
            if tool.id != "\(tool.providerId)/\(tool.name)" {
                throw fail("tool id \"\(tool.id)\" is not \"<providerId>/<name>\" (\(tool.providerId), \(tool.name))")
            }
            if artifact.providers[tool.providerId] == nil { throw fail("tool \(tool.id) names unknown provider \"\(tool.providerId)\"") }
            let primary = artifact.selectors[tool.selector]
            if primary == nil || primary?.toolId != tool.id || primary?.kind != "tool" {
                throw fail("tool \(tool.id) names selector \"\(tool.selector)\", which is not its primary selector")
            }
        }

        for key in artifact.selectors.keys.sorted() {
            let selector = artifact.selectors[key]!
            if selector.canonical != key { throw fail("selector key \"\(key)\" holds selector \"\(selector.canonical)\"") }
            guard let owner = artifact.tools[selector.toolId] else {
                throw fail("selector \(key) points at unknown tool \"\(selector.toolId)\"")
            }
            if selector.kind == "tool" && owner.selector != key {
                throw fail("selector \(key) claims to be the primary selector of \(selector.toolId)")
            }
            if selector.vector.count != artifact.embedder.dims {
                throw fail("selector \(key) has \(selector.vector.count) dimensions; the embedder has \(artifact.embedder.dims)")
            }
        }

        var stats: [String: AnyCodableValue] = [:]
        if case .dict(let s)? = object["stats"] { stats = s }
        let actual: [(String, Int)] = [
            ("toolCount", artifact.tools.count),
            ("selectorCount", artifact.selectors.count),
            ("providerCount", artifact.providers.count),
            ("collisionCount", artifact.collisions.count),
            ("duplicateCount", artifact.duplicates.count),
        ]
        for (name, count) in actual {
            let recorded = stats[name]?.numberValue.map { Int($0) }
            if recorded != count {
                throw fail("stats.\(name) is \(recorded.map(String.init) ?? "missing") but the artifact holds \(count)")
            }
        }
    }
}

// MARK: - Building

extension ArtifactV1 {

    /// Build a 1.0 artifact from a compilation result and the manifests it
    /// was compiled from. `embedder` must be the fingerprint of the embedder
    /// the compiler used. The result is validated before it is returned, so
    /// this can only produce artifacts the loader accepts.
    ///
    /// `extensions` holds tool-specific metadata (covered by the content
    /// hash, ignored by loaders), e.g. `["dream": ...]`.
    public static func build(
        result: CompilationResult,
        manifests: [ProviderManifest],
        embedder: EmbedderFingerprint,
        extensions: [String: AnyCodableValue]? = nil
    ) throws -> ArtifactV1 {
        var definitions: [String: (manifest: ProviderManifest, tool: ToolDefinition)] = [:]
        for manifest in manifests {
            for tool in manifest.tools {
                let id = "\(manifest.id)/\(tool.name)"
                if definitions[id] == nil { definitions[id] = (manifest, tool) }
            }
        }

        var providers: [String: AnyCodableValue] = [:]
        var tools: [String: AnyCodableValue] = [:]
        var selectors: [String: AnyCodableValue] = [:]

        for ref in result.tools {
            guard let (manifest, tool) = definitions[ref.id] else {
                throw ArtifactFormatError("Compiled tool \(ref.id) has no definition in the supplied manifests")
            }
            if providers[manifest.id] == nil { providers[manifest.id] = .dict(providerJSON(manifest)) }

            var entry: [String: AnyCodableValue] = [
                "id": .string(ref.id),
                "providerId": .string(ref.providerId),
                "name": .string(ref.toolName),
                "description": .string(tool.description),
                "inputSchema": .dict(tool.inputSchema.jsonValue),
                "transportType": .string(manifest.transportType.rawValue),
                "selector": .string(ref.selector),
            ]
            if let title = tool.title { entry["title"] = .string(title) }
            if let output = tool.outputSchema { entry["outputSchema"] = .dict(output.jsonValue) }
            if let annotations = tool.annotations, !annotations.isEmpty { entry["annotations"] = .dict(annotations.jsonValue) }
            if let hints = tool.compilerHints { entry["compilerHints"] = .dict(hints.jsonValue) }
            if let uri = tool.uiResourceUri {
                var ui: [String: AnyCodableValue] = ["resourceUri": .string(uri)]
                if let visibility = tool.uiVisibility { ui["visibility"] = .array(visibility.map { .string($0) }) }
                entry["ui"] = .dict(ui)
            }
            tools[ref.id] = .dict(entry)

            for (canonical, kind) in [(ref.selector, "tool")] + ref.aliases.map({ ($0, "alias") }) {
                guard let selector = result.selectors[canonical] else {
                    throw ArtifactFormatError("Selector \(canonical) of \(ref.id) is missing from the compilation result")
                }
                selectors[canonical] = .dict([
                    "canonical": .string(canonical),
                    "toolId": .string(ref.id),
                    "kind": .string(kind),
                    "vector": .array(selector.vector.map { .double(Double($0)) }),
                ])
            }
        }

        var body: [String: AnyCodableValue] = [
            "formatVersion": .string(ARTIFACT_FORMAT_VERSION),
            "embedder": .dict(embedder.jsonValue),
            "providers": .dict(providers),
            "tools": .dict(tools),
            "selectors": .dict(selectors),
            "collisions": .array(result.collisions.map {
                .dict([
                    "selectorA": .string($0.selectorA),
                    "selectorB": .string($0.selectorB),
                    "similarity": .double($0.similarity),
                    "hint": .string($0.hint),
                ])
            }),
            "duplicates": .array(result.duplicates.map {
                .dict([
                    "toolA": .string($0.toolA),
                    "toolB": .string($0.toolB),
                    "selectorA": .string($0.selectorA),
                    "selectorB": .string($0.selectorB),
                    "similarity": .double($0.similarity),
                ])
            }),
            "stats": .dict([
                "toolCount": .int(tools.count),
                "selectorCount": .int(selectors.count),
                "providerCount": .int(providers.count),
                "collisionCount": .int(result.collisions.count),
                "duplicateCount": .int(result.duplicates.count),
            ]),
        ]
        if let extensions { body["extensions"] = .dict(extensions) }
        body["contentHash"] = .string(try computeContentHash(body))
        return try validate(.dict(body), source: "built artifact")
    }

    private static func providerJSON(_ manifest: ProviderManifest) -> [String: AnyCodableValue] {
        var provider: [String: AnyCodableValue] = [
            "id": .string(manifest.id),
            "name": .string(manifest.name),
            "transportType": .string(manifest.transportType.rawValue),
        ]
        if let version = manifest.version { provider["version"] = .string(version) }
        if let launch = manifest.launch {
            provider["launch"] = .dict(launch.jsonValue)
        } else if let endpoint = manifest.endpoint {
            provider["launch"] = .dict(LaunchSpec.remote(manifest.transportType == .mcp ? "streamable-http" : "http", url: endpoint).jsonValue)
        }
        if let hints = manifest.compilerHints { provider["compilerHints"] = .dict(hints.jsonValue) }
        if let channel = manifest.channel, channel.isChannel {
            var c: [String: AnyCodableValue] = [
                "isChannel": .bool(true),
                "twoWay": .bool(channel.twoWay),
                "permissionRelay": .bool(channel.permissionRelay),
            ]
            if let reply = channel.replyToolName { c["replyToolName"] = .string(reply) }
            if let instructions = channel.instructions { c["instructions"] = .string(instructions) }
            provider["channel"] = .dict(c)
        }
        return provider
    }
}
