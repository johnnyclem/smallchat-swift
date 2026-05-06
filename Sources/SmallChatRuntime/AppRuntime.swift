import Foundation
import SmallChatCore

// MARK: - AppRuntimeOptions

public struct AppRuntimeOptions: Sendable {
    public var viewCacheSize: Int
    public var selectorThreshold: Float

    public init(
        viewCacheSize: Int = 512,
        selectorThreshold: Float = 0.95
    ) {
        self.viewCacheSize = viewCacheSize
        self.selectorThreshold = selectorThreshold
    }
}

// MARK: - AppRuntime

/// AppRuntime -- top-level runtime for App/UI dispatch.
///
/// Parallel to `ToolRuntime` but for the App/UI layer.
/// Owns the `ComponentSelectorTable`, `ViewCache`, and the registered `AppClass` instances.
///
/// Key contract: `uiDispatch` **never throws** — unknown intents and internal errors
/// both return `.notFound`. Callers needing detailed error information should use
/// `uiDispatchStream`.
public actor AppRuntime {
    public let selectorTable: ComponentSelectorTable
    public let viewCache: ViewCache
    private let embedder: any Embedder
    private var appClasses: [String: AppClass] = [:]
    private var artifact: AppArtifact?

    public init(
        vectorIndex: any VectorIndex,
        embedder: any Embedder,
        options: AppRuntimeOptions = AppRuntimeOptions()
    ) {
        self.embedder = embedder
        self.viewCache = ViewCache(maxSize: options.viewCacheSize)
        self.selectorTable = ComponentSelectorTable(
            index: vectorIndex,
            embedder: embedder,
            threshold: options.selectorThreshold
        )
    }

    // MARK: - Registration

    /// Register an AppClass for dispatch.
    public func registerClass(_ appClass: AppClass) {
        appClasses[appClass.appId] = appClass
    }

    /// Load a compiled artifact, reconstructing AppClass instances from `AppArtifact`.
    public func load(_ artifact: AppArtifact) {
        self.artifact = artifact
        for (appId, data) in artifact.appClasses {
            let appClass = AppClass(
                appId: appId,
                name: data.name,
                uiResourceUri: data.uiResourceUri
            )
            for canonical in data.componentSelectors {
                if let uri = artifact.uriMap[canonical] {
                    appClass.addComponent(canonical, uri: uri)
                }
            }
            appClasses[appId] = appClass
        }
    }

    // MARK: - Dispatch

    /// Graceful-null UI dispatch. Never throws.
    ///
    /// Resolution order:
    /// 1. Check `ViewCache` for a previously resolved view.
    /// 2. Embed intent → query `ComponentSelectorTable`.
    /// 3. Walk registered `AppClass` dispatch tables.
    /// 4. Return `.notFound` if nothing matches or any step fails.
    public func uiDispatch(
        intent: String,
        args: [String: any Sendable]? = nil
    ) async -> UIDispatchResult {
        do {
            // Resolve intent to a component selector
            guard let selector = try await selectorTable.resolve(intent: intent) else {
                return .notFound
            }

            // ViewCache hit
            if let cached = await viewCache.lookup(selector) {
                return .resolved(appId: cached.appId, uri: cached.uri, content: cached.content)
            }

            // Walk AppClass dispatch tables
            for appClass in appClasses.values {
                guard let uri = appClass.resolveComponent(selector.canonical) else { continue }

                // Retrieve content from artifact's embeddedHTML if available
                let content = artifact?.embeddedHTML[uriBase(uri)] ?? ""

                let view = CachedView(appId: appClass.appId, uri: uri, content: content)
                await viewCache.store(selector, view: view)

                return .resolved(appId: appClass.appId, uri: uri, content: content)
            }

            return .notFound
        } catch {
            return .notFound
        }
    }

    /// Streaming UI dispatch — same `DispatchEvent` sequence as `ToolRuntime.dispatchStream`.
    ///
    /// Event sequence: `.resolving` → `.toolStart` → `.chunk` → `.done` (or `.error`)
    public func uiDispatchStream(
        intent: String,
        args: [String: any Sendable]? = nil
    ) -> AsyncThrowingStream<DispatchEvent, Error> {
        appUIDispatchStream(runtime: self, intent: intent, args: args)
    }
}

// MARK: - Private Helpers

/// Strip the fragment (`#component-name`) from a URI to get the base HTML URI.
private func uriBase(_ uri: String) -> String {
    if let range = uri.range(of: "#") {
        return String(uri[uri.startIndex..<range.lowerBound])
    }
    return uri
}

/// Free function that drives `AppRuntime.uiDispatchStream` — mirrors the pattern used by
/// `smallchatDispatchStream` in `Dispatch.swift`, avoiding actor-isolation capture issues.
private func appUIDispatchStream(
    runtime: AppRuntime,
    intent: String,
    args: [String: any Sendable]?
) -> AsyncThrowingStream<DispatchEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            continuation.yield(.resolving(intent: intent))

            let result = await runtime.uiDispatch(intent: intent, args: args)

            switch result {
            case .notFound:
                continuation.yield(.error(
                    message: "No app component found for intent: \(intent)",
                    metadata: nil
                ))
                continuation.finish()

            case let .resolved(appId, uri, content):
                continuation.yield(.toolStart(
                    toolName: uri,
                    providerId: appId,
                    confidence: 1.0,
                    selector: intent
                ))
                continuation.yield(.chunk(content: .string(content), index: 0))
                continuation.yield(.done(result: ToolResult(codableContent: .string(content))))
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
