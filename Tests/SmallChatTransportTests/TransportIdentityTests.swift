import Testing
import Foundation
import SmallChatCore
@testable import SmallChatTransport

/// Transport ids name circuit breakers and log lines, so two live transports must
/// never share one. Before 1.0 each actor bumped a nonisolated `static var counter`
/// (a data race, and a compile error under Swift 6.2+), so concurrent inits could
/// mint the same id.
@Suite("Transport ids")
struct TransportIdentityTests {

    private static let count = 400

    private static func concurrentIds(_ make: @escaping @Sendable () -> String) async -> [String] {
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<count {
                group.addTask { make() }
            }
            var ids: [String] = []
            for await id in group { ids.append(id) }
            return ids
        }
    }

    @Test("Concurrently created LocalTransports get distinct ids")
    func localIdsAreUnique() async {
        let ids = await Self.concurrentIds { LocalTransport().id }
        #expect(Set(ids).count == Self.count)
        #expect(ids.allSatisfy { $0.hasPrefix("local-") })
    }

    @Test("Concurrently created HTTPTransports get distinct ids")
    func httpIdsAreUnique() async {
        let url = URL(string: "http://127.0.0.1:9")!
        let ids = await Self.concurrentIds { HTTPTransport(config: TransportConfig(baseURL: url)).id }
        #expect(Set(ids).count == Self.count)
        #expect(ids.allSatisfy { $0.hasPrefix("http-") })
    }

    @Test("Concurrently created MCPSSETransports get distinct ids")
    func sseIdsAreUnique() async {
        let url = URL(string: "http://127.0.0.1:9/mcp")!
        let ids = await Self.concurrentIds { MCPSSETransport(config: MCPSSEConfig(url: url)).id }
        #expect(Set(ids).count == Self.count)
        #expect(ids.allSatisfy { $0.hasPrefix("mcp-sse-") })
    }

    @Test("Concurrently created RtkTransports get distinct ids")
    func rtkIdsAreUnique() async {
        let ids = await Self.concurrentIds { RtkTransport(wrapping: LocalTransport()).id }
        #expect(Set(ids).count == Self.count)
        #expect(ids.allSatisfy { $0.hasPrefix("rtk-") })
    }

    #if os(macOS) || os(Linux)
    @Test("Concurrently created MCPStdioTransports get distinct ids")
    func stdioIdsAreUnique() async {
        let ids = await Self.concurrentIds { MCPStdioTransport(config: MCPStdioConfig(command: "true")).id }
        #expect(Set(ids).count == Self.count)
        #expect(ids.allSatisfy { $0.hasPrefix("mcp-stdio-") })
    }
    #endif
}
