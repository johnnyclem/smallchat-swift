import Testing
import Foundation
import SmallChatCore
@testable import SmallChatTransport

// The subprocess-backed transports exist only on macOS and Linux.
#if os(macOS) || os(Linux)

// MARK: - Fixtures

/// Writes `contents` to an executable file in a fresh temporary directory.
private func makeExecutable(_ name: String, _ contents: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("smallchat-subprocess-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// A stdio MCP server in Perl (present on macOS and in every Debian/Ubuntu
/// image, including the swift containers CI uses).
///
/// Modes for `tools/call`: `big N` answers with N copies of "€" (3 UTF-8 bytes
/// each, so pipe reads split code points); `silent` never answers; `exit`
/// exits without answering.
private let fakeMCPServer = #"""
#!/usr/bin/env perl
use strict; use warnings;
$| = 1;
binmode(STDOUT, ':raw');
my $mode = $ARGV[0] // 'big';
my $n = $ARGV[1] // 1000;
while (my $line = <STDIN>) {
  my ($method) = $line =~ /"method"\s*:\s*"([^"]+)"/;
  my ($id) = $line =~ /"id"\s*:\s*(\d+)/;
  next unless defined $method && defined $id;
  $method =~ s{\\/}{/}g; # JSONSerialization may escape "/" as "\/"
  if ($method eq 'initialize') {
    print qq({"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}\n);
  } elsif ($method eq 'tools/call') {
    next if $mode eq 'silent';
    exit 0 if $mode eq 'exit';
    my $text = "\xe2\x82\xac" x $n;
    print qq({"jsonrpc":"2.0","id":$id,"result":{"content":[{"type":"text","text":"$text"}]}}\n);
  }
}
"""#

private func stdioTransport(mode: String, count: Int = 0) throws -> MCPStdioTransport {
    let script = try makeExecutable("fake-mcp.pl", fakeMCPServer)
    return MCPStdioTransport(config: MCPStdioConfig(
        command: "perl",
        args: [script, mode, String(count)],
        initTimeout: 20
    ))
}

/// Seconds elapsed since `start`.
private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

// MARK: - withTimeout

@Suite("withTimeout")
struct WithTimeoutTests {

    /// An operation that ignores cancellation: it resumes only after 5 s.
    private static func uncooperative() async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { cont.resume(returning: 1) }
        }
    }

    @Test("fires on time even when the operation ignores cancellation")
    func firesForUncooperativeOperation() async {
        let start = ContinuousClock.now
        do {
            _ = try await withTimeout(seconds: 0.2) { try await Self.uncooperative() }
            Issue.record("expected a timeout")
        } catch TransportError.timeout(let ms) {
            #expect(ms == 200)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(seconds(since: start) < 2)
    }

    @Test("TimeoutMiddleware fires on time even when the operation ignores cancellation")
    func middlewareFiresForUncooperativeOperation() async {
        let start = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            _ = try await TimeoutMiddleware(timeout: 0.2).execute { try await Self.uncooperative() }
        }
        #expect(seconds(since: start) < 2)
    }

    @Test("returns the result and cancels nothing when the operation is fast")
    func returnsResult() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("propagates the operation's error")
    func propagatesError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await withTimeout(seconds: 5) { () async throws -> Int in throw Boom() }
        }
    }

    @Test("cancels the operation when the deadline passes")
    func cancelsOperation() async throws {
        let cancelled = PlatformLock(initialState: false)
        do {
            _ = try await withTimeout(seconds: 0.1) {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
            }
        } catch {}
        // The operation's task observes the cancellation shortly after.
        for _ in 0..<50 where !cancelled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cancelled.withLock { $0 })
    }
}

// MARK: - MCPStdioTransport

@Suite("MCPStdioTransport reliability", .timeLimit(.minutes(1)))
struct MCPStdioReliabilityTests {

    @Test("multibyte output split across pipe reads arrives intact")
    func multibyteAcrossPipeReads() async throws {
        let count = 70_000 // 210 KB of 3-byte code points
        let transport = try stdioTransport(mode: "big", count: count)
        defer { Task { try? await transport.disconnect() } }

        let output = try await transport.execute(input: TransportInput(toolName: "big", timeout: 30))
        let body = try #require(output.body)
        let result = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.count == count)
        #expect(text.allSatisfy { $0 == "€" })
    }

    @Test("a call the server never answers times out")
    func timeoutFires() async throws {
        let transport = try stdioTransport(mode: "silent")
        defer { Task { try? await transport.disconnect() } }
        try await transport.connect()

        let start = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            _ = try await transport.execute(input: TransportInput(toolName: "never", timeout: 1))
        }
        #expect(seconds(since: start) < 5)
    }

    @Test("a server that exits fails the pending call instead of hanging")
    func exitFailsPendingCall() async throws {
        let transport = try stdioTransport(mode: "exit")
        defer { Task { try? await transport.disconnect() } }

        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await transport.execute(input: TransportInput(toolName: "bye", timeout: 30))
        }
        #expect(seconds(since: start) < 10)
    }
}

// MARK: - rtk filter subprocess

@Suite("rtk filter subprocess", .timeLimit(.minutes(1)))
struct RtkFilterSubprocessTests {

    @Test("output larger than the pipe buffer does not deadlock")
    func largeOutput() async throws {
        let rtk = try makeExecutable("rtk", "#!/bin/sh\nexec cat\n")
        let content = Data(repeating: UInt8(ascii: "y"), count: 300 * 1024)

        let start = ContinuousClock.now
        let filtered = try await runRtkFilter(binary: rtk, content: content, level: .default, timeoutMs: 20_000)
        #expect(filtered == content)
        #expect(seconds(since: start) < 10)
    }

    @Test("a filter that never finishes times out and is stopped")
    func timeoutFires() async throws {
        let rtk = try makeExecutable("rtk", "#!/bin/sh\nexec sleep 30\n")
        // Larger than a pipe buffer, so the write to stdin blocks until the
        // process is stopped (and must not kill this process with SIGPIPE).
        let content = Data(repeating: UInt8(ascii: "z"), count: 300 * 1024)

        let start = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            _ = try await runRtkFilter(binary: rtk, content: content, level: .default, timeoutMs: 500)
        }
        #expect(seconds(since: start) < 5)
    }

    @Test("a non-zero exit is an error")
    func nonZeroExit() async throws {
        let rtk = try makeExecutable("rtk", "#!/bin/sh\ncat >/dev/null\nexit 3\n")
        await #expect(throws: TransportError.self) {
            _ = try await runRtkFilter(binary: rtk, content: Data("x".utf8), level: .default, timeoutMs: 10_000)
        }
    }
}

#endif
