import Foundation

/// Walk `$PATH` and return the absolute path of the first directory containing
/// an executable named `binary`, or `nil` if no match is found.
///
/// Mirrors the TypeScript `rtk-which` module; avoids shelling out to
/// `/usr/bin/which`, which is not portable across all targets.
func rtkWhich(_ binary: String) async -> String? {
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = "\(dir)/\(binary)"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}
