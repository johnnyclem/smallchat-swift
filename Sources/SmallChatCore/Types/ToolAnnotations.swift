// MARK: - ToolAnnotations

/// MCP tool annotations (the fields artifact format 1.0 records). Hints
/// from the upstream server, not guarantees; the dispatch policy uses them
/// to decide which tools count as destructive (`isDestructive`).
public struct ToolAnnotations: Sendable, Codable, Equatable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    /// Lenient decoding: a field of the wrong type is dropped, as the
    /// artifact writer drops it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        readOnlyHint = try? container.decodeIfPresent(Bool.self, forKey: .readOnlyHint)
        destructiveHint = try? container.decodeIfPresent(Bool.self, forKey: .destructiveHint)
        idempotentHint = try? container.decodeIfPresent(Bool.self, forKey: .idempotentHint)
        openWorldHint = try? container.decodeIfPresent(Bool.self, forKey: .openWorldHint)
    }

    /// True when no field is set.
    public var isEmpty: Bool {
        title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil && openWorldHint == nil
    }

    /// The annotations as a JSON object (only the fields that are set).
    public var jsonValue: [String: AnyCodableValue] {
        var object: [String: AnyCodableValue] = [:]
        if let title { object["title"] = .string(title) }
        if let readOnlyHint { object["readOnlyHint"] = .bool(readOnlyHint) }
        if let destructiveHint { object["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { object["idempotentHint"] = .bool(idempotentHint) }
        if let openWorldHint { object["openWorldHint"] = .bool(openWorldHint) }
        return object
    }
}
