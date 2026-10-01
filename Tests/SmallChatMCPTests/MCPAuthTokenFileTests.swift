import Foundation
import Testing
import SmallChatMCP

@Suite("serve's bearer-token file (SW-REV-07)")
struct MCPAuthTokenFileTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a missing file is created 0600 in a 0700 directory, then read back")
    func createsPrivately() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("smallchat/serve-token").path

        let first = try MCPAuthTokenFile.loadOrCreate(at: path)
        #expect(first.created)
        #expect(first.token.count == 64 && first.token.allSatisfy(\.isHexDigit))
        #expect(try mode(path) == 0o600)
        #expect(try mode(root.appendingPathComponent("smallchat").path) == 0o700)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == first.token + "\n")

        let second = try MCPAuthTokenFile.loadOrCreate(at: path)
        #expect(!second.created)
        #expect(second.token == first.token)
    }

    @Test("a token file other users can read is refused until it is 0600")
    func refusesSharedFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token").path
        try Data("tok-123\n".utf8).write(to: URL(fileURLWithPath: path))
        for shared in [0o644, 0o640, 0o604, 0o620] {
            try FileManager.default.setAttributes([.posixPermissions: shared], ofItemAtPath: path)
            #expect(throws: MCPAuthTokenFileError.self, "mode \(String(shared, radix: 8))") {
                try MCPAuthTokenFile.loadOrCreate(at: path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let loaded = try MCPAuthTokenFile.loadOrCreate(at: path)
        #expect(loaded.token == "tok-123" && !loaded.created)
    }

    @Test("an empty file gets a new token; a dangling symlink is not followed")
    func emptyAndSymlink() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty").path
        #expect(FileManager.default.createFile(atPath: empty, contents: Data(), attributes: [.posixPermissions: 0o600]))
        let replaced = try MCPAuthTokenFile.loadOrCreate(at: empty)
        #expect(replaced.created)
        #expect(try mode(empty) == 0o600)

        let target = root.appendingPathComponent("elsewhere").path
        let link = root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(throws: MCPAuthTokenFileError.self) { try MCPAuthTokenFile.loadOrCreate(at: link) }
        #expect(!FileManager.default.fileExists(atPath: target), "the token was written through the symlink")
    }
}
