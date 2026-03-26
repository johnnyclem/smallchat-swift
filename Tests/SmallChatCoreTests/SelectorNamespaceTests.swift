import Testing
@testable import SmallChatCore

@Suite("SelectorNamespace")
struct SelectorNamespaceTests {

    // MARK: - Shadowing Protection

    @Test("Protected core selector blocks shadowing from another provider")
    func protectedBlocksShadowing() {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")

        let entry = ns.checkShadowing("delete:user")
        #expect(entry != nil)
        #expect(entry?.ownerClass == "CoreProvider")
        #expect(entry?.swizzlable == false)
    }

    @Test("assertNoShadowing throws for protected selector from different provider")
    func assertNoShadowingThrows() {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")

        #expect(throws: SelectorShadowingError.self) {
            try ns.assertNoShadowing("PluginProvider", ["delete:user"])
        }
    }

    @Test("assertNoShadowing allows same owner to re-register")
    func sameOwnerCanShadow() throws {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")

        try ns.assertNoShadowing("CoreProvider", ["delete:user"])
    }

    @Test("assertNoShadowing allows unregistered selectors")
    func unregisteredSelectorsPass() throws {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")

        try ns.assertNoShadowing("PluginProvider", ["create:user", "update:user"])
    }

    // MARK: - Swizzlable Override

    @Test("Swizzlable selector does not block shadowing")
    func swizzlableDoesNotBlock() {
        let ns = SelectorNamespace()
        ns.registerCore("format:output", ownerClass: "CoreProvider", swizzlable: true)

        let entry = ns.checkShadowing("format:output")
        #expect(entry == nil)
    }

    @Test("assertNoShadowing passes for swizzlable selectors")
    func assertNoShadowingPassesForSwizzlable() throws {
        let ns = SelectorNamespace()
        ns.registerCore("format:output", ownerClass: "CoreProvider", swizzlable: true)

        try ns.assertNoShadowing("PluginProvider", ["format:output"])
    }

    @Test("markSwizzlable toggles protection off")
    func markSwizzlableTogglesOff() {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")

        #expect(ns.checkShadowing("delete:user") != nil)

        let result = ns.markSwizzlable("delete:user")
        #expect(result == true)
        #expect(ns.checkShadowing("delete:user") == nil)
        #expect(ns.isSwizzlable("delete:user") == true)
    }

    @Test("markProtected toggles protection on")
    func markProtectedTogglesOn() {
        let ns = SelectorNamespace()
        ns.registerCore("format:output", ownerClass: "CoreProvider", swizzlable: true)

        #expect(ns.checkShadowing("format:output") == nil)

        let result = ns.markProtected("format:output")
        #expect(result == true)
        #expect(ns.checkShadowing("format:output") != nil)
        #expect(ns.isSwizzlable("format:output") == false)
    }

    @Test("markSwizzlable returns false for unregistered selector")
    func markSwizzlableReturnsFalseUnregistered() {
        let ns = SelectorNamespace()
        #expect(ns.markSwizzlable("unknown") == false)
    }

    @Test("markProtected returns false for unregistered selector")
    func markProtectedReturnsFalseUnregistered() {
        let ns = SelectorNamespace()
        #expect(ns.markProtected("unknown") == false)
    }

    // MARK: - Batch Registration

    @Test("registerCoreSelectors registers multiple selectors")
    func batchRegistration() {
        let ns = SelectorNamespace()
        ns.registerCoreSelectors("CoreProvider", selectors: [
            (canonical: "a", swizzlable: false),
            (canonical: "b", swizzlable: true),
            (canonical: "c", swizzlable: false),
        ])

        #expect(ns.size == 3)
        #expect(ns.isCore("a"))
        #expect(ns.isCore("b"))
        #expect(ns.isCore("c"))
        #expect(!ns.isSwizzlable("a"))
        #expect(ns.isSwizzlable("b"))
    }

    // MARK: - Unregistration

    @Test("unregisterCore removes the selector")
    func unregisterCoreRemoves() {
        let ns = SelectorNamespace()
        ns.registerCore("delete:user", ownerClass: "CoreProvider")
        #expect(ns.isCore("delete:user"))

        let removed = ns.unregisterCore("delete:user")
        #expect(removed == true)
        #expect(!ns.isCore("delete:user"))
        #expect(ns.size == 0)
    }

    @Test("unregisterCore returns false for unknown selector")
    func unregisterCoreReturnsFalseUnknown() {
        let ns = SelectorNamespace()
        #expect(ns.unregisterCore("unknown") == false)
    }

    // MARK: - Queries

    @Test("allCore returns all registered entries")
    func allCoreReturnsAll() {
        let ns = SelectorNamespace()
        ns.registerCore("a", ownerClass: "X")
        ns.registerCore("b", ownerClass: "Y")

        let all = ns.allCore()
        #expect(all.count == 2)
        let canonicals = all.map(\.canonical).sorted()
        #expect(canonicals == ["a", "b"])
    }

    @Test("getEntry returns nil for unregistered")
    func getEntryNilForUnregistered() {
        let ns = SelectorNamespace()
        #expect(ns.getEntry("nope") == nil)
    }
}
