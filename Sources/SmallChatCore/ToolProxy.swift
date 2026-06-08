import Foundation
import os

/// ToolProxy -- lazy-loaded tool that loads its full schema only on first dispatch.
/// Equivalent to NSProxy: exists as lightweight stand-in until first message.
///
/// Mutable state is protected by an `OSAllocatedUnfairLock` so the proxy can
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

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let schemaLoader: @Sendable () async throws -> ToolSchema

    public var schema: ToolSchema? { lock.withLock { $0.schema } }

    public init(
        providerId: String,
        toolName: String,
        transportType: TransportType,
        schemaLoader: @escaping @Sendable () async throws -> ToolSchema
    ) {
        self.providerId = providerId
        self.toolName = toolName
        self.transportType = transportType
        self.schemaLoader = schemaLoader
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
        try await realize()
        // In a full implementation, this would route through a transport
        // For now, return a placeholder indicating the tool was called
        return ToolResult(
            content: AnyCodableValue.dict(["tool": .string(toolName), "status": .string("executed")]),
            isError: false,
            metadata: nil
        )
    }
}
