import Foundation
#if canImport(os)
import os
#endif

#if canImport(os)

/// Lock used by every SmallChat module. On Apple platforms this is Apple's
/// `OSAllocatedUnfairLock`; elsewhere it is the `NSLock`-backed shim below.
///
/// `package`-scoped so the package never exports a type that shadows the
/// platform's own `OSAllocatedUnfairLock` for consumers.
package typealias PlatformLock<State> = OSAllocatedUnfairLock<State>

#else

/// Portable stand-in for Apple's `OSAllocatedUnfairLock` on platforms (e.g. Linux)
/// that do not ship the `os` module. Implements only the subset of the API used
/// in this package: `init(initialState:)`, `init(uncheckedState:)`, `withLock`,
/// and `withLockUnchecked`, with the same `Sendable` requirements as the Apple type
/// so Linux builds reject what Apple builds reject.
///
/// Backed by `NSLock`. The lock is `Sendable` only when its `State` is.
package struct PlatformLock<State> {
    private final class Storage {
        var state: State
        let lock = NSLock()
        init(_ state: State) { self.state = state }
    }

    private let storage: Storage

    package init(initialState: State) where State: Sendable {
        self.storage = Storage(initialState)
    }

    package init(uncheckedState initialState: State) {
        self.storage = Storage(initialState)
    }

    @discardableResult
    package func withLock<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        try withLockUnchecked(body)
    }

    @discardableResult
    package func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return try body(&storage.state)
    }
}

extension PlatformLock: @unchecked Sendable where State: Sendable {}

#endif
