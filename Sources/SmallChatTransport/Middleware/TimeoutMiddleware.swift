import Foundation
import SmallChatCore

/// Timeout middleware that wraps transport execution with a configurable deadline.
///
/// Delegates to `withTimeout(seconds:_:)`, so the deadline holds even when the
/// operation ignores cancellation. Mirrors the TypeScript `withTimeout` function.
public struct TimeoutMiddleware: Sendable {

    /// Default timeout in seconds.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// Execute an async operation with a timeout.
    ///
    /// - Parameters:
    ///   - duration: Override the default timeout (in seconds). Pass `nil` to use the default.
    ///   - operation: The async operation to execute.
    /// - Returns: The result if the operation completes within the timeout.
    /// - Throws: `TransportError.timeout` if the deadline is exceeded.
    public func execute<T: Sendable>(
        timeout duration: TimeInterval? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTimeout(seconds: duration ?? timeout, operation)
    }
}

/// Run `operation` with a deadline.
///
/// The operation runs in its own task. Whichever happens first decides the
/// result, exactly once: the operation finishing, the deadline passing
/// (`TransportError.timeout`), or the caller being cancelled
/// (`CancellationError`). In the last two cases the operation's task is
/// cancelled and this function returns at once; it does not wait for an
/// operation that ignores cancellation (a task-group race would).
///
/// A `seconds` value that is not positive and finite means no deadline.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = ResumeOnce<T>()
    let work = Task {
        do {
            outcome.resume(with: .success(try await operation()))
        } catch {
            outcome.resume(with: .failure(error))
        }
    }
    var timer: Task<Void, Never>?
    if seconds > 0, seconds.isFinite {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        let durationMs = Int((seconds * 1000).rounded())
        timer = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return // cancelled: the operation finished first
            }
            outcome.resume(with: .failure(TransportError.timeout(durationMs: durationMs)))
        }
    }
    defer {
        work.cancel()
        timer?.cancel()
    }
    return try await withTaskCancellationHandler {
        try await outcome.value()
    } onCancel: {
        outcome.resume(with: .failure(CancellationError()))
    }
}

/// A one-shot result slot that any number of racers may try to fill; only the
/// first `resume(with:)` counts. `value()` waits for it (or returns at once if
/// it is already filled).
final class ResumeOnce<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, Error>?
        var continuation: CheckedContinuation<T, Error>?
    }

    private let state = PlatformLock(initialState: State())

    /// Offer a result. Returns `true` if it was the first.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        let (first, waiter) = state.withLock { state -> (Bool, CheckedContinuation<T, Error>?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            let waiter = state.continuation
            state.continuation = nil
            return (true, waiter)
        }
        waiter?.resume(with: result)
        return first
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let ready: Result<T, Error>? = state.withLock { state in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
