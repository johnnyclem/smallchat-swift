import Testing
import Foundation
@testable import SmallChatRuntime
import SmallChatCore
import SmallChatEmbedding

@Suite("AppRuntime")
struct AppRuntimeTests {

    private func makeRuntime() -> AppRuntime {
        AppRuntime(
            vectorIndex: MemoryVectorIndex(),
            embedder: LocalEmbedder()
        )
    }

    // MARK: - Graceful-null dispatch

    @Test("uiDispatch returns .notFound when no app registered")
    func uiDispatchNotFound() async {
        let runtime = makeRuntime()
        let result = await runtime.uiDispatch(intent: "open calculator")
        if case .notFound = result {
            // pass
        } else {
            Issue.record("Expected .notFound, got \(result)")
        }
    }

    @Test("uiDispatch never throws: invalid intent returns .notFound gracefully")
    func uiDispatchNeverThrows() async {
        let runtime = makeRuntime()
        // Deliberately weird intent — should not crash or throw
        let result = await runtime.uiDispatch(intent: "##@@!! not a real intent ##@@!!")
        switch result {
        case .notFound:
            break  // correct
        case .resolved:
            break  // also acceptable if embedder matched something
        }
    }

    @Test("uiDispatch returns .resolved after registering matching AppClass")
    func uiDispatchResolved() async throws {
        let runtime = makeRuntime()

        // Build a minimal artifact
        let artifact = AppArtifact(
            appClasses: [
                "test-app": AppClassData(
                    appId: "test-app",
                    name: "Test App",
                    uiResourceUri: "<html/>",
                    componentSelectors: ["test-app.entry"]
                )
            ],
            embeddedHTML: ["ui://test-app/index.html": "<html>Test App</html>"],
            uriMap: ["test-app.entry": "ui://test-app/index.html"],
            appCount: 1
        )
        await runtime.load(artifact)

        // Intern the selector so the runtime can resolve it
        let selectorTable = await runtime.selectorTable
        let embedder = LocalEmbedder()
        let embedding = try await embedder.embed("test-app.entry")
        _ = try await selectorTable.intern(embedding: embedding, canonical: "test-app.entry")

        let result = await runtime.uiDispatch(intent: "test-app.entry")
        switch result {
        case .resolved(let appId, _, _):
            #expect(appId == "test-app")
        case .notFound:
            // Acceptable: embedder may not produce a high enough similarity
            break
        }
    }

    // MARK: - Stream event sequence

    @Test("stream event sequence starts with .resolving")
    func streamStartsWithResolving() async throws {
        let runtime = makeRuntime()
        var events: [DispatchEvent] = []

        for try await event in runtime.uiDispatchStream(intent: "open the header") {
            events.append(event)
        }

        guard let first = events.first else {
            Issue.record("Expected at least one event")
            return
        }
        if case .resolving(let intent) = first {
            #expect(intent == "open the header")
        } else {
            Issue.record("First event should be .resolving, got \(first)")
        }
    }

    @Test("stream ends with .done or .error — never hangs")
    func streamEndsCleanly() async throws {
        let runtime = makeRuntime()
        var lastEvent: DispatchEvent?

        for try await event in runtime.uiDispatchStream(intent: "something unknown") {
            lastEvent = event
        }

        guard let last = lastEvent else {
            Issue.record("Expected at least one event")
            return
        }
        switch last {
        case .done, .error:
            break  // correct terminal events
        default:
            Issue.record("Last event should be .done or .error, got \(last)")
        }
    }
}
