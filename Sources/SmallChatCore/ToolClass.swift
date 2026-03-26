import Foundation
import os

/// ToolClass -- a group of related tools from one provider.
/// Equivalent to an Objective-C class with dispatch table, protocols, superclass chain, and overload tables.
///
/// All mutable state is protected by an `OSAllocatedUnfairLock` to prevent data races
/// when accessed concurrently from the actor-based runtime.
public final class ToolClass: @unchecked Sendable {
    public let name: String

    private struct State {
        var dispatchTable: [String: any ToolIMP] = [:]
        var overloadTables: [String: OverloadTable] = [:]
        var protocols: [ToolProtocolDef] = []
        var superclass: ToolClass?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init(name: String) { self.name = name }

    // MARK: - Property Accessors

    /// Snapshot of the current dispatch table.
    public var dispatchTable: [String: any ToolIMP] {
        lock.withLock { $0.dispatchTable }
    }

    /// Snapshot of the current overload tables.
    public var overloadTables: [String: OverloadTable] {
        lock.withLock { $0.overloadTables }
    }

    /// Snapshot of the current protocol conformances.
    public var protocols: [ToolProtocolDef] {
        lock.withLock { $0.protocols }
    }

    /// The superclass in the isa chain.
    public var superclass: ToolClass? {
        get { lock.withLock { $0.superclass } }
        set { lock.withLock { $0.superclass = newValue } }
    }

    // MARK: - Mutation

    /// Register a method (selector -> IMP mapping)
    public func addMethod(_ selector: ToolSelector, imp: any ToolIMP) {
        lock.withLock { $0.dispatchTable[selector.canonical] = imp }
    }

    /// Register an overloaded method -- same selector, different signature.
    /// The first overload registered also becomes the default IMP in the dispatch table.
    public func addOverload(
        _ selector: ToolSelector,
        signature: SCMethodSignature,
        imp: any ToolIMP,
        originalToolName: String? = nil,
        isSemanticOverload: Bool = false
    ) throws {
        try lock.withLock { state in
            if state.overloadTables[selector.canonical] == nil {
                state.overloadTables[selector.canonical] = OverloadTable(selectorCanonical: selector.canonical)
            }
            try state.overloadTables[selector.canonical]!.register(
                signature,
                imp: imp,
                originalToolName: originalToolName,
                isSemanticOverload: isSemanticOverload
            )
            // First overload becomes the default IMP
            if state.dispatchTable[selector.canonical] == nil {
                state.dispatchTable[selector.canonical] = imp
            }
        }
    }

    /// Declare conformance to a protocol
    public func addProtocol(_ proto: ToolProtocolDef) {
        lock.withLock { $0.protocols.append(proto) }
    }

    /// Replace the IMP for a selector. Returns the previous IMP (if any).
    @discardableResult
    public func swizzleMethod(_ selector: ToolSelector, newImp: any ToolIMP) -> (any ToolIMP)? {
        lock.withLock { state in
            let original = state.dispatchTable[selector.canonical]
            state.dispatchTable[selector.canonical] = newImp
            return original
        }
    }

    // MARK: - Queries

    /// Check protocol conformance
    public func conformsTo(_ proto: ToolProtocolDef) -> Bool {
        lock.withLock { state in
            state.protocols.contains { $0.name == proto.name }
        }
    }

    /// Resolve a selector by walking dispatch table and isa chain.
    /// Like Obj-C method resolution: own table -> superclass -> nil (triggers forwarding).
    public func resolveSelector(_ selector: ToolSelector) -> (any ToolIMP)? {
        let (direct, sup) = lock.withLock { state in
            (state.dispatchTable[selector.canonical], state.superclass)
        }
        if let direct { return direct }
        return sup?.resolveSelector(selector)
    }

    /// Resolve with positional args (overload resolution)
    public func resolveSelectorWithArgs(
        _ selector: ToolSelector,
        args: [any Sendable]
    ) throws -> OverloadResolutionResult? {
        let (table, sup) = lock.withLock { state in
            (state.overloadTables[selector.canonical], state.superclass)
        }
        if let table, table.size > 0 {
            return try table.resolve(args)
        }
        return try sup?.resolveSelectorWithArgs(selector, args: args)
    }

    /// Resolve with named args
    public func resolveSelectorWithNamedArgs(
        _ selector: ToolSelector,
        namedArgs: [String: any Sendable]
    ) throws -> OverloadResolutionResult? {
        let (table, sup) = lock.withLock { state in
            (state.overloadTables[selector.canonical], state.superclass)
        }
        if let table, table.size > 0 {
            return try table.resolveNamed(namedArgs)
        }
        return try sup?.resolveSelectorWithNamedArgs(selector, namedArgs: namedArgs)
    }

    /// Hardened resolve with validation (prevents Type Confusion)
    public func validateAndResolveSelectorWithNamedArgs(
        _ selector: ToolSelector,
        namedArgs: [String: any Sendable]
    ) throws -> OverloadResolutionResult? {
        let (table, sup) = lock.withLock { state in
            (state.overloadTables[selector.canonical], state.superclass)
        }
        if let table, table.size > 0 {
            return try table.validateAndResolveNamed(namedArgs)
        }
        return try sup?.validateAndResolveSelectorWithNamedArgs(selector, namedArgs: namedArgs)
    }

    /// Hardened resolve with positional args
    public func validateAndResolveSelectorWithArgs(
        _ selector: ToolSelector,
        args: [any Sendable]
    ) throws -> OverloadResolutionResult? {
        let (table, sup) = lock.withLock { state in
            (state.overloadTables[selector.canonical], state.superclass)
        }
        if let table, table.size > 0 {
            return try table.validateAndResolve(args)
        }
        return try sup?.validateAndResolveSelectorWithArgs(selector, args: args)
    }

    /// Check if a selector has overloads
    public func hasOverloads(_ selector: ToolSelector) -> Bool {
        guard let table = lock.withLock({ $0.overloadTables[selector.canonical] }) else {
            return false
        }
        return table.size > 1
    }

    /// respondsToSelector: equivalent
    public func canHandle(_ selector: ToolSelector) -> Bool {
        resolveSelector(selector) != nil
    }

    /// All selectors this class responds to
    public func allSelectors() -> [String] {
        let (keys, sup) = lock.withLock { state in
            (Array(state.dispatchTable.keys), state.superclass)
        }
        var selectors = keys
        if let sup {
            selectors.append(contentsOf: sup.allSelectors())
        }
        return selectors
    }
}
