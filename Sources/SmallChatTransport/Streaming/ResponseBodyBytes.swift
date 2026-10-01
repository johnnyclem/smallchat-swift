import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - ResponseBodyBytes

#if canImport(FoundationNetworking)

/// A response body as an async sequence of bytes, yielded as they arrive.
///
/// swift-corelibs-foundation (Linux) has no `URLSession.bytes(for:)`, so this
/// sequence is fed by a streaming `URLSessionDataDelegate` instead (see
/// `URLSession.streamingBytes(for:)`).
struct ResponseBodyBytes: AsyncSequence, Sendable {
    typealias Element = UInt8

    fileprivate let chunks: AsyncThrowingStream<Data, Error>

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
        private var buffer = Data()
        private var index = 0

        fileprivate init(chunks: AsyncThrowingStream<Data, Error>.AsyncIterator) {
            self.chunks = chunks
        }

        mutating func next() async throws -> UInt8? {
            while index >= buffer.endIndex {
                guard let chunk = try await chunks.next() else { return nil }
                buffer = chunk
                index = chunk.startIndex
            }
            defer { index += 1 }
            return buffer[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator())
    }
}

#else

/// A response body as an async sequence of bytes, yielded as they arrive.
typealias ResponseBodyBytes = URLSession.AsyncBytes

#endif

// MARK: - URLSession.streamingBytes

extension URLSession {

    /// Starts `request` and returns as soon as the response head has arrived;
    /// the body streams through the returned byte sequence.
    ///
    /// On Apple platforms this is `bytes(for:)`. On Linux it runs the request on
    /// a dedicated session (same configuration) whose delegate forwards each
    /// received chunk, because swift-corelibs-foundation lacks `bytes(for:)`.
    /// Ending the iteration early, or cancelling the calling task, cancels the
    /// request.
    func streamingBytes(for request: URLRequest) async throws -> (ResponseBodyBytes, URLResponse) {
        #if canImport(FoundationNetworking)
        let (chunks, chunkContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = StreamingDataDelegate(chunks: chunkContinuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        chunkContinuation.onTermination = { _ in task.cancel() }

        let response: URLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.awaitResponse(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (ResponseBodyBytes(chunks: chunks), response)
        #else
        return try await bytes(for: request)
        #endif
    }
}

#if canImport(FoundationNetworking)

/// Bridges a data task's delegate callbacks to the response continuation and
/// the body chunk stream. Invalidates its session when the task completes.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private let chunks: AsyncThrowingStream<Data, Error>.Continuation

    init(chunks: AsyncThrowingStream<Data, Error>.Continuation) {
        self.chunks = chunks
    }

    func awaitResponse(_ continuation: CheckedContinuation<URLResponse, Error>) {
        lock.withLock { responseContinuation = continuation }
    }

    private func takeResponseContinuation() -> CheckedContinuation<URLResponse, Error>? {
        lock.withLock {
            defer { responseContinuation = nil }
            return responseContinuation
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        takeResponseContinuation()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        takeResponseContinuation()?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error {
            chunks.finish(throwing: error)
        } else {
            chunks.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

#endif
