import SwiftUI
import SmallChat

struct DoctorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("System Doctor")
                    .font(.largeTitle.bold())

                Text("Run diagnostics to check embedder, vector index, and runtime health.")
                    .foregroundStyle(.secondary)

                Divider()

                // Run Button
                HStack {
                    Button(action: { Task { await runDiagnostics() } }) {
                        Label("Run Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isRunningDiagnostics)

                    if appState.isRunningDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running...")
                            .foregroundStyle(.secondary)
                    }
                }

                // Results
                if !appState.diagnosticResults.isEmpty {
                    let passed = appState.diagnosticResults.filter(\.passed).count
                    let total = appState.diagnosticResults.count
                    let allPassed = passed == total

                    GroupBox {
                        HStack {
                            Image(systemName: allPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(allPassed ? .green : .orange)
                                .font(.title2)
                            Text(allPassed ? "All checks passed (\(passed)/\(total))" : "\(passed)/\(total) checks passed")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(4)
                    }

                    VStack(spacing: 8) {
                        ForEach(appState.diagnosticResults) { check in
                            HStack(alignment: .top) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(check.passed ? .green : .red)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.name)
                                        .fontWeight(.medium)
                                    Text(check.detail)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(.fill.quinary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Diagnostics

    @MainActor
    private func runDiagnostics() async {
        appState.isRunningDiagnostics = true
        appState.diagnosticResults = []

        // 1. Swift Runtime
        #if swift(>=6.0)
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Swift Runtime",
            detail: "Swift 6+ available",
            passed: true
        ))
        #else
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Swift Runtime",
            detail: "Swift pre-6.0 (6.0+ recommended)",
            passed: false
        ))
        #endif

        // Platform
        #if os(macOS)
        let platform = "macOS"
        #elseif os(iOS)
        let platform = "iOS"
        #elseif os(Linux)
        let platform = "Linux"
        #else
        let platform = "Unknown"
        #endif
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Platform",
            detail: platform,
            passed: true
        ))

        // 2. Embedder
        let embedder = LocalEmbedder()
        do {
            let vec = try await embedder.embed("hello world")
            appState.diagnosticResults.append(DiagnosticCheck(
                name: "LocalEmbedder",
                detail: "OK (\(vec.count)-dim vector)",
                passed: true
            ))
        } catch {
            appState.diagnosticResults.append(DiagnosticCheck(
                name: "LocalEmbedder",
                detail: "FAILED: \(error)",
                passed: false
            ))
        }

        // 3. Vector Index
        let index = MemoryVectorIndex()
        do {
            let testVec: [Float] = Array(repeating: 0.1, count: 384)
            try await index.insert(id: "test", vector: testVec)
            let results = try await index.search(query: testVec, topK: 1, threshold: 0.5)
            let ok = results.count == 1 && results[0].id == "test"
            try await index.remove(id: "test")
            appState.diagnosticResults.append(DiagnosticCheck(
                name: "MemoryVectorIndex",
                detail: ok ? "OK (insert/search/remove)" : "FAILED (unexpected results)",
                passed: ok
            ))
        } catch {
            appState.diagnosticResults.append(DiagnosticCheck(
                name: "MemoryVectorIndex",
                detail: "FAILED: \(error)",
                passed: false
            ))
        }

        // 4. Cosine Similarity
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [1, 0, 0, 0]
        let c: [Float] = [0, 1, 0, 0]
        let simSame = cosineSimilarity(a, b)
        let simOrtho = cosineSimilarity(a, c)
        let cosineOk = abs(simSame - 1.0) < 0.001 && abs(simOrtho) < 0.001
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Cosine Similarity",
            detail: cosineOk
                ? "OK (same=\(String(format: "%.3f", simSame)), ortho=\(String(format: "%.3f", simOrtho)))"
                : "FAILED (same=\(simSame), ortho=\(simOrtho))",
            passed: cosineOk
        ))

        // 5. Canonicalize
        let canon = canonicalize("find my recent documents")
        let canonOk = canon == "find:recent:documents"
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Canonicalize",
            detail: canonOk
                ? "OK (\"find my recent documents\" -> \"\(canon)\")"
                : "UNEXPECTED: got \"\(canon)\"",
            passed: canonOk
        ))

        // 6. Database check
        let dbPath = "smallchat.db"
        let dbExists = FileManager.default.fileExists(atPath: dbPath)
        appState.diagnosticResults.append(DiagnosticCheck(
            name: "Database",
            detail: dbExists
                ? "\(dbPath): exists"
                : "\(dbPath): not yet created (will be created on first use)",
            passed: true
        ))

        appState.isRunningDiagnostics = false
    }
}
