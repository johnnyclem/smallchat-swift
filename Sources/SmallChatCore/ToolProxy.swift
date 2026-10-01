import Foundation
#if canImport(os)
import os
#endif

/// ToolProxy -- lazy-loaded tool that loads its full schema only on first dispatch.
/// Equivalent to NSProxy: exists as lightweight stand-in until first message.
///
/// A proxy runs a tool only through the `executor` it was given. Without one
/// (the compiler's proxies have none: a compiled tool has no transport bound
/// yet), `execute` throws `ToolNotExecutableError` instead of reporting a
/// success that never happened.
///
/// Mutable state is protected by a `PlatformLock` so the proxy can
/// satisfy `ToolIMP`'s nonisolated, synchronous `schema` requirement without
/// crossing into actor-isolated code.
public final class ToolProxy: ToolIMP, @unchecked Sendable {
    public let providerId: String
    public let toolName: String
    public let transportType: TransportType

    private struct State {
        var schema: ToolSchema?
        var realized: Bool = false
    }

    private let lock = PlatformLock(initialState: State())
    private let schemaLoader: @Sendable () async throws -> ToolSchema
    private let executor: (@Sendable ([String: any Sendable]) async throws -> ToolResult)?

    public var schema: ToolSchema? { lock.withLock { $0.schema } }

    public init(
        providerId: String,
        toolName: String,
        transportType: TransportType,
        schemaLoader: @escaping @Sendable () async throws -> ToolSchema,
        executor: (@Sendable ([String: any Sendable]) async throws -> ToolResult)? = nil
    ) {
        self.providerId = providerId
        self.toolName = toolName
        self.transportType = transportType
        self.schemaLoader = schemaLoader
        self.executor = executor
    }

    private func realize() async throws {
        if lock.withLock({ $0.realized }) { return }
        let loaded = try await schemaLoader()
        lock.withLock { state in
            state.schema = loaded
            state.realized = true
        }
    }

    public func loadSchema() async throws -> ToolSchema {
        try await realize()
        return lock.withLock { $0.schema }!
    }

    public func execute(args: [String: any Sendable]) async throws -> ToolResult {
        guard let executor else {
            throw ToolNotExecutableError(providerId: providerId, toolName: toolName)
        }
        try await realize()
        return try await executor(args)
    }
}

/// A tool was dispatched that has no way to run (no transport or executor
/// is bound to it).
public struct ToolNotExecutableError: Error, Sendable, CustomStringConvertible {
    public let providerId: String
    public let toolName: String

    public init(providerId: String, toolName: String) {
        self.providerId = providerId
        self.toolName = toolName
    }

    public var description: String {
        "\(providerId)/\(toolName) has no executor bound; nothing was run"
    }
}
