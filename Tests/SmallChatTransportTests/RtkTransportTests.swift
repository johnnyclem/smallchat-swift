import Testing
import Foundation
import SmallChatCore
@testable import SmallChatTransport

// MARK: - Mock Transport

/// Thread-unsafe spy transport used for unit tests.
final class MockTransport: Transport, @unchecked Sendable {

    let id: String
    var transportType: TransportType? { .local }

    var executeCallCount = 0
    var lastExecuteInput: TransportInput?
    var disconnectCallCount = 0

    var responseBody: Data?
    var responseIsError: Bool = false

    init(id: String = "mock-1", responseBody: Data? = nil) {
        self.id = id
        self.responseBody = responseBody
    }

    func execute(input: TransportInput) async throws -> TransportOutput {
        executeCallCount += 1
        lastExecuteInput = input
        var out = TransportOutput(body: responseBody)
        if responseIsError {
            out.statusCode = 500
            out.metadata["isError"] = "true"
        }
        return out
    }

    func disconnect() async throws {
        disconnectCallCount += 1
    }
}

// MARK: - Test Constants

private let smallContent = "tiny".data(using: .utf8)!
private let largeContent = Data(repeating: UInt8(ascii: "x"), count: 1024)

// MARK: - Tests

@Suite("RtkTransport")
struct RtkTransportTests {

    // A binary path that cannot exist so binary resolution always fails.
    private static let noSuchBinary = "/nonexistent/__rtk__"

    @Test("RTK binary not found — noop metadata attached, content unchanged")
    func binaryNotFound() async throws {
        let inner = MockTransport(responseBody: largeContent)
        let transport = RtkTransport(
            wrapping: inner,
            config: RtkConfig(binaryPath: Self.noSuchBinary)
        )
        let output = try await transport.execute(input: TransportInput())
        #expect(output.rtkMetadata != nil)
        #expect(output.rtkMetadata?.enabled == false)
        #expect(output.rtkMetadata?.mode == .none)
        #expect(output.body == largeContent)
    }

    @Test("enabled=false — full passthrough, no rtkMetadata")
    func disabledPassthrough() async throws {
        let inner = MockTransport(responseBody: largeContent)
        let transport = RtkTransport(
            wrapping: inner,
            config: RtkConfig(enabled: false)
        )
        let output = try await transport.execute(input: TransportInput())
        #expect(output.rtkMetadata == nil)
    }

    @Test("Prefix mode — rewrites eligible command")
    func prefixModeRewrites() async throws {
        let inner = MockTransport()
        let transport = RtkTransport(wrapping: inner, config: RtkConfig())
        var input = TransportInput()
        input.args["command"] = AnySendable("git status")
        _ = try await transport.execute(input: input)
        let cmd = inner.lastExecuteInput?.args["command"]?.as(String.self)
        #expect(cmd == "rtk git status")
    }

    @Test("Prefix mode — no double-wrap")
    func prefixModeNoDoubleWrap() async throws {
        let inner = MockTransport()
        let transport = RtkTransport(wrapping: inner, config: RtkConfig())
        var input = TransportInput()
        input.args["command"] = AnySendable("rtk git status")
        _ = try await transport.execute(input: input)
        let cmd = inner.lastExecuteInput?.args["command"]?.as(String.self)
        #expect(cmd == "rtk git status")
    }

    @Test("Prefix mode — non-eligible command unchanged")
    func prefixModeNonEligible() async throws {
        let inner = MockTransport()
        let transport = RtkTransport(wrapping: inner, config: RtkConfig())
        var input = TransportInput()
        input.args["command"] = AnySendable("my_custom_tool --run")
        _ = try await transport.execute(input: input)
        let cmd = inner.lastExecuteInput?.args["command"]?.as(String.self)
        #expect(cmd == "my_custom_tool --run")
    }

    @Test("Filter threshold — content below 512 B yields noop metadata")
    func filterThreshold() async throws {
        let inner = MockTransport(responseBody: smallContent)
        let transport = RtkTransport(
            wrapping: inner,
            config: RtkConfig(binaryPath: Self.noSuchBinary)
        )
        let output = try await transport.execute(input: TransportInput())
        #expect(output.rtkMetadata?.enabled == false)
    }

    @Test("Metadata shape — inputBytes, outputBytes, savedPct present; mode=none when binary absent")
    func metadataShape() async throws {
        let inner = MockTransport(responseBody: largeContent)
        let transport = RtkTransport(
            wrapping: inner,
            config: RtkConfig(binaryPath: Self.noSuchBinary)
        )
        let output = try await transport.execute(input: TransportInput())
        let meta = try #require(output.rtkMetadata)
        #expect(meta.inputBytes >= 0)
        #expect(meta.outputBytes >= 0)
        #expect(meta.savedPct >= 0)
        #expect(meta.mode == .none)
    }

    @Test("Type passthrough — transportType mirrors inner")
    func typePassthrough() {
        let inner = MockTransport()
        let transport = RtkTransport(wrapping: inner, config: RtkConfig())
        #expect(transport.transportType == .local)
        #expect(transport.transportType == inner.transportType)
    }

    @Test("dispose() — inner disconnect called exactly once")
    func disposeDelegate() async throws {
        let inner = MockTransport()
        let transport = RtkTransport(wrapping: inner, config: RtkConfig())
        try await transport.disconnect()
        #expect(inner.disconnectCallCount == 1)
    }

    @Test("Error result — filter skipped, noop metadata attached")
    func errorResultSkipped() async throws {
        let inner = MockTransport(responseBody: largeContent)
        inner.responseIsError = true
        let transport = RtkTransport(
            wrapping: inner,
            config: RtkConfig(binaryPath: Self.noSuchBinary)
        )
        let output = try await transport.execute(input: TransportInput())
        #expect(output.rtkMetadata?.enabled == false)
        #expect(output.rtkMetadata?.mode == .none)
    }

    @Test("withRtk factory — returns RtkTransport mirroring inner type")
    func withRtkFactory() {
        let inner = MockTransport()
        let transport = withRtk(inner)
        #expect(transport is RtkTransport)
        #expect(transport.transportType == inner.transportType)
    }

    @Test("Prefix mode — all 22 eligible prefixes recognised")
    func allEligiblePrefixes() {
        let samples = [
            "git status", "cargo build", "npm install", "npx tsc",
            "pnpm run", "yarn add", "pytest tests/", "python -m pytest",
            "go test ./...", "go build .", "grep -r foo", "rg pattern",
            "find . -name", "ls -la", "cat README", "eslint src/",
            "tsc --noEmit", "docker ps", "kubectl get", "aws s3 ls",
            "ruff check", "golangci-lint run",
        ]
        for cmd in samples {
            #expect(isRtkEligibleCommand(cmd))
        }
        #expect(!isRtkEligibleCommand("my_custom_tool --run"))
    }

    @Test("filterContentWithRtk — returns uncompressed when binary absent")
    func filterContentStandalone() async {
        let result = await filterContentWithRtk(
            content: largeContent,
            config: RtkConfig(binaryPath: Self.noSuchBinary)
        )
        #expect(result.enabled == false)
        #expect(result.savedPct == 0)
        #expect(result.compressed == largeContent)
    }
}
