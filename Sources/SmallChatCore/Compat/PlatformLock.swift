import Foundation

#if !canImport(os)

/// Portable drop-in for Apple's `OSAllocatedUnfairLock` on platforms (e.g. Linux)
/// that do not ship the `os` module. Implements only the subset of the API used
/// in this package: `init(initialState:)`, `withLock`, and `withLockUnchecked`.
///
/// Backed by `NSLock`. State is protected by the lock; the type is marked
/// `@unchecked Sendable` to mirror the platform type's contract.
public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private final class Storage {
        var state: State
        let lock = NSLock()
        init(_ state: State) { self.state = state }
    }

    private let storage: Storage

    public init(initialState: State) {
        self.storage = Storage(initialState)
    }

    public init(uncheckedState initialState: State) {
        self.storage = Storage(initialState)
    }

    @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return try body(&storage.state)
    }

    @discardableResult
    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}

#endif
