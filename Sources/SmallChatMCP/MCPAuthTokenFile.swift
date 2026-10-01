// MARK: - MCPAuthTokenFile — the bearer token `smallchat serve --auth` reads

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a bearer-token file can't be used.
public struct MCPAuthTokenFileError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(path): \(reason)" }
}

/// The file that holds the MCP server's bearer token.
///
/// The token lets its holder call every tool, so only its owner may read
/// the file. An existing file that gives group or other users any access is
/// refused (the error says to `chmod 600` it). A new file is created by
/// `open(O_CREAT | O_EXCL)` with mode 0600, so it is never readable by
/// anyone else, not even while it is written, and an existing file or
/// symlink at the path is never followed or overwritten. A missing parent
/// directory is created with mode 0700.
public enum MCPAuthTokenFile {

    /// The token in `path` (surrounding whitespace trimmed), or a fresh
    /// token written to it when the file is missing or empty. `created`
    /// tells which.
    public static func loadOrCreate(at path: String) throws -> (token: String, created: Bool) {
        if let existing = try read(path) { return (existing, false) }

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MCPAuthTokenFileError(path: path, reason: "couldn't create \(directory): \(error.localizedDescription)")
            }
        }

        let token = MCPServerConfig.generateAuthToken()
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            // Created by someone else just now: use theirs.
            if code == EEXIST, let existing = try read(path) { return (existing, false) }
            throw MCPAuthTokenFileError(path: path, reason: "couldn't create the token file: \(String(cString: strerror(code)))")
        }
        let written = Array((token + "\n").utf8).withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        close(fd)
        guard written else {
            unlink(path)
            throw MCPAuthTokenFileError(path: path, reason: "couldn't write the token file")
        }
        return (token, true)
    }

    /// The token an existing file holds; nil when there is no file. An
    /// empty file is removed (a new token replaces it). Throws when the
    /// file is not a regular file or other users may access it.
    private static func read(_ path: String) throws -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw MCPAuthTokenFileError(path: path, reason: String(cString: strerror(code)))
        }
        guard info.st_mode & 0o170000 == 0o100000 else {  // S_IFMT, S_IFREG
            throw MCPAuthTokenFileError(path: path, reason: "not a regular file")
        }
        let mode = info.st_mode & 0o777
        guard mode & 0o077 == 0 else {
            throw MCPAuthTokenFileError(
                path: path,
                reason: "other users can access the token file (mode \(String(mode, radix: 8))); run `chmod 600 \(path)` or remove it"
            )
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MCPAuthTokenFileError(path: path, reason: "couldn't read the token file")
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            unlink(path)
            return nil
        }
        return token
    }
}
