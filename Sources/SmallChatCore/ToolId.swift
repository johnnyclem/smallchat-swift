// MARK: - Canonical tool id

/// A string that is not a canonical tool id `<providerId>/<toolName>`.
public struct InvalidToolIdError: Error, Sendable, CustomStringConvertible {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }

    public var description: String { "Invalid tool id \"\(id)\": \(reason)" }
}

/// The canonical tool id `<providerId>/<toolName>`: the suite-wide identity
/// of one upstream tool (artifacts, call digests, proofs, policies). The
/// provider id is non-empty and has no `/`; the tool name is non-empty and
/// is the upstream name verbatim.
public func makeToolId(providerId: String, toolName: String) throws -> String {
    if providerId.isEmpty || providerId.contains("/") {
        throw InvalidToolIdError(id: "\(providerId)/\(toolName)", reason: "the provider id must be non-empty and must not contain \"/\"")
    }
    if toolName.isEmpty {
        throw InvalidToolIdError(id: "\(providerId)/\(toolName)", reason: "the tool name must be non-empty")
    }
    return "\(providerId)/\(toolName)"
}

/// Split a canonical tool id at its first `/` (`p/a/b` is provider `p`,
/// tool `a/b`). Throws for an empty id, an id without `/`, or an empty
/// provider id or tool name.
public func parseToolId(_ id: String) throws -> (providerId: String, toolName: String) {
    guard let slash = id.firstIndex(of: "/") else {
        throw InvalidToolIdError(id: id, reason: "expected \"<providerId>/<toolName>\"")
    }
    let providerId = String(id[..<slash])
    let toolName = String(id[id.index(after: slash)...])
    guard !providerId.isEmpty, !toolName.isEmpty else {
        throw InvalidToolIdError(id: id, reason: "expected \"<providerId>/<toolName>\"")
    }
    return (providerId, toolName)
}

// MARK: - MCP aggregate names

/// Separator between provider id and upstream tool name in aggregate mode.
public let mcpAggregateSeparator = "__"

/// Whether a provider id can prefix aggregate MCP names unambiguously: only
/// `[A-Za-z0-9_-]`, no `__`, not ending in `_` (so the first `__` of a name
/// always ends the provider id).
public func isAggregateProviderId(_ providerId: String) -> Bool {
    !providerId.isEmpty
        && providerId.unicodeScalars.allSatisfy(isMCPNameScalar)
        && !providerId.contains(mcpAggregateSeparator)
        && !providerId.hasSuffix("_")
}

/// Whether `name` matches `^[A-Za-z0-9_-]{1,128}$`.
public func isValidMCPToolName(_ name: String) -> Bool {
    (1...128).contains(name.utf8.count) && name.unicodeScalars.allSatisfy(isMCPNameScalar)
}

/// The aggregate MCP name of a tool, `<providerId>__<toolName>`, or nil when
/// the tool cannot be exposed that way (spec/tool-id: it is then served only
/// under `--provider <id>`, never renamed).
public func mcpAggregateName(providerId: String, toolName: String) -> String? {
    guard isAggregateProviderId(providerId) else { return nil }
    let name = providerId + mcpAggregateSeparator + toolName
    return isValidMCPToolName(name) ? name : nil
}

private func isMCPNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return true
    default: return false
    }
}
