import Foundation
import SmallChatCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Subprocess plumbing shared by MCPStdioTransport and the rtk filter. iOS has
// no Foundation.Process, so this is macOS/Linux only.
#if os(macOS) || os(Linux)

/// Holds a non-Sendable value (a FileHandle or Pipe) for a closure that runs
/// on another thread. The handle is only used from that thread.
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Low-level pipe I/O that never blocks a cooperative thread, never raises an
/// Objective-C exception or traps on a broken pipe, and never lets SIGPIPE
/// kill the process.
enum PipeIO {

    /// Write all of `data` to `handle`. Returns `false` if the read end is
    /// closed (EPIPE) or the write fails; the caller decides what that means.
    /// Blocks until the reader has taken everything, so call it off the
    /// cooperative pool (see `writeInBackground`).
    static func writeAll(_ data: Data, to handle: FileHandle) -> Bool {
        let fd = handle.fileDescriptor
        #if canImport(Darwin)
        // Darwin: report EPIPE instead of raising SIGPIPE for this descriptor.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #else
        // Linux: SIGPIPE is thread-directed for pipe writes. Block it on this
        // thread for the write, then consume it if the write raised it.
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask)
        defer {
            var pending = sigset_t()
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 {
                var immediately = timespec(tv_sec: 0, tv_nsec: 0)
                _ = sigtimedwait(&pipeSignal, nil, &immediately)
            }
            pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        }
        #endif
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    /// Write `data` to `handle` on a dedicated thread, optionally closing the
    /// handle afterwards, then call `completion` with the outcome.
    static func writeInBackground(
        _ data: Data,
        to handle: FileHandle,
        closeAfterwards: Bool,
        completion: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        let box = UncheckedSendableBox(handle)
        let thread = Thread {
            let ok = writeAll(data, to: box.value)
            if closeAfterwards { try? box.value.close() }
            completion(ok)
        }
        thread.name = "smallchat.pipe-writer"
        thread.start()
    }

    /// Read `handle` on a dedicated thread until end of file. Chunks are
    /// delivered in order, as raw bytes (a chunk may end inside a UTF-8 code
    /// point; callers must buffer bytes, not decode chunks).
    static func readUntilEOF(
        _ handle: FileHandle,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        let box = UncheckedSendableBox(handle)
        let thread = Thread {
            let fd = box.value.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    onChunk(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            onEOF()
        }
        thread.name = "smallchat.pipe-reader"
        thread.start()
    }

    /// Ask `process` to stop (SIGTERM), then kill it (SIGKILL) if it is still
    /// running after `grace`.
    static func stop(_ process: Process, grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        let box = UncheckedSendableBox(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if box.value.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// What a finished subprocess produced.
struct SubprocessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Run `executable` with `input` on stdin and collect stdout and stderr.
///
/// stdin is written while stdout and stderr are read, each on its own thread,
/// so output larger than a pipe buffer cannot deadlock the exchange. When
/// `timeoutMs` passes first the process is stopped and the call throws
/// `TransportError.timeout`. stderr keeps only its last `stderrLimit` bytes.
func runSubprocess(
    executable: String,
    arguments: [String],
    input: Data,
    timeoutMs: Int,
    stderrLimit: Int = 64 * 1024
) async throws -> SubprocessResult {
    struct Collected: Sendable {
        var stdout = Data()
        var stderr = Data()
        var openStreams = 2
        var status: Int32?
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let collected = PlatformLock(initialState: Collected())
    let outcome = ResumeOnce<SubprocessResult>()
    let finishIfDone: @Sendable () -> Void = {
        let done: SubprocessResult? = collected.withLock { state in
            guard state.openStreams == 0, let status = state.status else { return nil }
            return SubprocessResult(status: status, stdout: state.stdout, stderr: state.stderr)
        }
        if let done { outcome.resume(with: .success(done)) }
    }

    process.terminationHandler = { finished in
        let status = finished.terminationStatus
        collected.withLock { $0.status = status }
        finishIfDone()
    }
    try process.run()

    PipeIO.readUntilEOF(stdout.fileHandleForReading, onChunk: { chunk in
        collected.withLock { $0.stdout.append(chunk) }
    }, onEOF: {
        collected.withLock { $0.openStreams -= 1 }
        finishIfDone()
    })
    PipeIO.readUntilEOF(stderr.fileHandleForReading, onChunk: { chunk in
        collected.withLock { state in
            state.stderr.append(chunk)
            if state.stderr.count > stderrLimit {
                state.stderr = Data(state.stderr.suffix(stderrLimit))
            }
        }
    }, onEOF: {
        collected.withLock { $0.openStreams -= 1 }
        finishIfDone()
    })
    PipeIO.writeInBackground(input, to: stdin.fileHandleForWriting, closeAfterwards: true)

    do {
        return try await withTimeout(seconds: Double(timeoutMs) / 1000) {
            try await outcome.value()
        }
    } catch {
        PipeIO.stop(process)
        throw error
    }
}

#endif // os(macOS) || os(Linux)
