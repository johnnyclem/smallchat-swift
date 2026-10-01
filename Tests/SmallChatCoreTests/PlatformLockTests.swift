import Testing
import Foundation
@testable import SmallChatCore

private func requireSendable<T: Sendable>(_: T.Type) {}

@Suite("PlatformLock")
struct PlatformLockTests {

    @Test("withLock serializes concurrent mutation")
    func serializesConcurrentMutation() async {
        let lock = PlatformLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { lock.withLock { $0 += 1 } }
            }
        }
        #expect(lock.withLock { $0 } == 1_000)
    }

    @Test("A lock over Sendable state is Sendable")
    func sendableWhenStateIsSendable() {
        // Compile-time check: the Linux shim is Sendable only when State is.
        requireSendable(PlatformLock<[String: Int]>.self)
    }
}
