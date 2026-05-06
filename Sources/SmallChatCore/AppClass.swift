import Foundation
import os

/// AppExtension -- new components bolted onto an AppClass (like an Obj-C category).
public struct AppExtension: Sendable {
    public let extendsAppId: String
    public let components: [(canonical: String, uri: String)]

    public init(extendsAppId: String, components: [(canonical: String, uri: String)]) {
        self.extendsAppId = extendsAppId
        self.components = components
    }
}

/// AppClass -- a registered App in the dispatch system.
///
/// Parallel to `ToolClass` but for the App/UI layer.
/// Maps component selector canonicals to `ui://` URIs, supports superclass
/// ISA-chain traversal, and accepts extensions that bolt in additional components.
///
/// All mutable state is protected by `OSAllocatedUnfairLock` matching the
/// thread-safety model of `ToolClass`.
public final class AppClass: @unchecked Sendable {
    public let appId: String
    public let name: String
    public let uiResourceUri: String?

    private struct State {
        var dispatchTable: [String: String] = [:]  // canonical → ui:// URI
        var superclass: AppClass?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init(appId: String, name: String, uiResourceUri: String? = nil) {
        self.appId = appId
        self.name = name
        self.uiResourceUri = uiResourceUri
    }

    // MARK: - Property Accessors

    public var dispatchTable: [String: String] {
        lock.withLock { $0.dispatchTable }
    }

    public var superclass: AppClass? {
        get { lock.withLock { $0.superclass } }
        set { lock.withLock { $0.superclass = newValue } }
    }

    // MARK: - Mutation

    /// Register a component selector → URI mapping.
    public func addComponent(_ canonical: String, uri: String) {
        lock.withLock { $0.dispatchTable[canonical] = uri }
    }

    /// Bolt in an extension's components.  Mirrors `ToolRuntime.loadCategory(_:)`.
    public func loadExtension(_ ext: AppExtension) {
        lock.withLock { state in
            for (canonical, uri) in ext.components {
                state.dispatchTable[canonical] = uri
            }
        }
    }

    // MARK: - Queries

    /// Resolve a component canonical by walking the dispatch table and ISA chain.
    /// Returns `nil` if not found (like Obj-C forwarding trigger).
    public func resolveComponent(_ canonical: String) -> String? {
        let (direct, sup) = lock.withLock { state in
            (state.dispatchTable[canonical], state.superclass)
        }
        if let direct { return direct }
        return sup?.resolveComponent(canonical)
    }

    /// Returns true if this class (or a superclass) handles the selector.
    public func canHandle(_ canonical: String) -> Bool {
        resolveComponent(canonical) != nil
    }

    /// All component canonicals this class responds to (own + inherited).
    public func allCanonicals() -> [String] {
        let (keys, sup) = lock.withLock { state in
            (Array(state.dispatchTable.keys), state.superclass)
        }
        var result = keys
        if let sup { result.append(contentsOf: sup.allCanonicals()) }
        return result
    }
}
