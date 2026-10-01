import ArgumentParser
import Foundation
import SmallChat

/// Read a compiled artifact (format 1.0) and build a runtime that resolves
/// against it with the embedder its fingerprint names. Exits with a readable
/// message when the file is not an intact 1.0 artifact (a 0.x artifact asks
/// for a recompile) or its embedder is not available.
func loadArtifactRuntime(_ path: String) async throws -> MCPToolkit {
    do {
        let artifact = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: path))
        return try await MCPToolkit.make(artifact: artifact)
    } catch let error as ArtifactVersionError {
        FileHandle.standardError.write(Data("\(error.message)\n".utf8))
        throw ExitCode.failure
    } catch let error as ArtifactFormatError {
        FileHandle.standardError.write(Data("\(error.message)\n".utf8))
        throw ExitCode.failure
    } catch let error as EmbedderMismatchError {
        FileHandle.standardError.write(Data("\(error.message)\n".utf8))
        throw ExitCode.failure
    }
}

/// The resolution of an intent, for people.
func describeResolution(_ resolution: Resolution, catalog: MCPToolCatalog) -> String {
    func serveName(_ toolId: String) -> String {
        catalog.tools.first { $0.toolId == toolId }.map { " (serve name \($0.name))" } ?? ""
    }
    var lines = [
        "Intent:  \"\(resolution.intent)\"",
        "Outcome: \(resolution.outcome.rawValue) (tier \(resolution.tier.rawValue), decision \(resolution.proof.decision.rawValue))",
    ]
    if let chosen = resolution.chosen {
        lines.append("Chosen:  \(chosen)\(serveName(chosen))")
    }
    if let reason = resolution.reason {
        lines.append("Reason:  \(reason)")
    }
    if resolution.candidates.isEmpty {
        lines.append("Candidates: none")
    } else {
        lines.append("Candidates:")
        for candidate in resolution.candidates {
            lines.append("  \(String(format: "%.4f", candidate.score))  \(candidate.tier.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))  \(candidate.toolId)")
        }
    }
    for excluded in resolution.proof.candidates where excluded.excluded != nil {
        lines.append("  excluded: \(excluded.toolId) (\(excluded.excluded!))")
    }
    lines.append("Proof:   \(resolution.proof.proofDigest)")
    lines.append("Nothing was executed.")
    return lines.joined(separator: "\n")
}
