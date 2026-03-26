import Testing
@testable import SmallChatCore

@Suite("SelectorNamespace")
struct SelectorNamespaceTests {

    // MARK: - Shadowing protection

    @Test("Protected selector blocks shadowing from different provider")
    func protectedBlocksShadowing() throws {
        let ns = SelectorNamespace()
        ns.registerCore("dispatch", ownerClass: "Runtime")

        let blocked = ns.checkShadowing("dispatch")
        #expect(blocked != nil)
        #expect(blocked?.ownerClass == "Runtime")
    }

    @Test("assertNoShadowing throws for protected selector from different provider")
    func assertNoShadowingThrows() {
        let ns = SelectorNamespace()
        ns.registerCore("dispatch", ownerClass: "Runtime")

        #expect(throws: SelectorShadowingError.self) {
            try ns.assertNoShadowing("PluginA", ["dispatch"])
        }
    }

    @Test("assertNoShadowing allows same owner class")
    func assertNoShadowingSameOwner() throws {
        let ns = SelectorNamespace()
        ns.registerCore("dispatch", ownerClass: "Runtime")

        // Same owner class should not throw
        try ns.assertNoShadowing("Runtime", ["dispatch"])
    }

    @Test("Non-core selector returns nil for checkShadowing")
    func nonCoreReturnsNil() {
        let ns = SelectorNamespace()
        let result = ns.checkShadowing("unknown:selector")
        #expect(result == nil)
    }

    // MARK: - Swizzlable override

    @Test("Swizzlable selector allows shadowing")
    func swizzlableAllowsShadowing() throws {
        let ns = SelectorNamespace()
        ns.registerCore("hook:event", ownerClass: "EventSystem", swizzlable: true)

        let blocked = ns.checkShadowing("hook:event")
        #expect(blocked == nil)

        // Should not throw even from different provider
        try ns.assertNoShadowing("PluginA", ["hook:event"])
    }

    @Test("markSwizzlable toggles protection off")
    func markSwizzlableToggles() {
        let ns = SelectorNamespace()
        ns.registerCore("log:event", ownerClass: "Logger")

        #expect(ns.isSwizzlable("log:event") == false)

        let result = ns.markSwizzlable("log:event")
        #expect(result == true)
        #expect(ns.isSwizzlable("log:event") == true)
        #expect(ns.checkShadowing("log:event") == nil)
    }

    @Test("markProtected toggles protection on")
    func markProtectedToggles() {
        let ns = SelectorNamespace()
        ns.registerCore("hook:event", ownerClass: "System", swizzlable: true)

        #expect(ns.isSwizzlable("hook:event") == true)

        let result = ns.markProtected("hook:event")
        #expect(result == true)
        #expect(ns.isSwizzlable("hook:event") == false)
        #expect(ns.checkShadowing("hook:event") != nil)
    }

    @Test("markSwizzlable returns false for unregistered selector")
    func markSwizzlableUnregistered() {
        let ns = SelectorNamespace()
        #expect(ns.markSwizzlable("nonexistent") == false)
    }

    @Test("markProtected returns false for unregistered selector")
    func markProtectedUnregistered() {
        let ns = SelectorNamespace()
        #expect(ns.markProtected("nonexistent") == false)
    }

    // MARK: - Batch registration

    @Test("registerCoreSelectors registers multiple selectors")
    func batchRegistration() {
        let ns = SelectorNamespace()
        ns.registerCoreSelectors("Runtime", selectors: [
            (canonical: "dispatch", swizzlable: false),
            (canonical: "resolve", swizzlable: false),
            (canonical: "hook", swizzlable: true),
        ])

        #expect(ns.size == 3)
        #expect(ns.isCore("dispatch"))
        #expect(ns.isCore("resolve"))
        #expect(ns.isCore("hook"))
        #expect(ns.isSwizzlable("hook"))
        #expect(!ns.isSwizzlable("dispatch"))
    }

    // MARK: - Inspection

    @Test("isCore and getEntry work correctly")
    func inspectionAPIs() {
        let ns = SelectorNamespace()
        ns.registerCore("test", ownerClass: "TestClass")

        #expect(ns.isCore("test"))
        #expect(!ns.isCore("other"))

        let entry = ns.getEntry("test")
        #expect(entry?.canonical == "test")
        #expect(entry?.ownerClass == "TestClass")
    }

    @Test("unregisterCore removes protection")
    func unregisterCore() {
        let ns = SelectorNamespace()
        ns.registerCore("temp", ownerClass: "System")

        #expect(ns.unregisterCore("temp") == true)
        #expect(ns.isCore("temp") == false)
        #expect(ns.size == 0)

        #expect(ns.unregisterCore("nonexistent") == false)
    }

    @Test("allCore returns all entries")
    func allCoreReturnsAll() {
        let ns = SelectorNamespace()
        ns.registerCore("a", ownerClass: "X")
        ns.registerCore("b", ownerClass: "Y")

        let all = ns.allCore()
        #expect(all.count == 2)
        let canonicals = Set(all.map(\.canonical))
        #expect(canonicals == ["a", "b"])
    }

    // MARK: - Error details

    @Test("SelectorShadowingError contains correct details")
    func errorDetails() {
        let ns = SelectorNamespace()
        ns.registerCore("dispatch", ownerClass: "Runtime")

        do {
            try ns.assertNoShadowing("EvilPlugin", ["dispatch"])
            Issue.record("Should have thrown")
        } catch let error as SelectorShadowingError {
            #expect(error.shadowedSelector == "dispatch")
            #expect(error.shadowingProvider == "EvilPlugin")
            #expect(error.existingProvider == "Runtime")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
