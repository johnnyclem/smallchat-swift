import Testing
@testable import SmallChatCore

@Suite("AppClass")
struct AppClassTests {

    // MARK: - Dispatch table

    @Test("addComponent → resolveComponent returns URI")
    func dispatchTable() {
        let appClass = AppClass(appId: "com.example", name: "Example", uiResourceUri: "<html/>")
        appClass.addComponent("com.example.header", uri: "ui://com.example/index.html#header")
        let uri = appClass.resolveComponent("com.example.header")
        #expect(uri == "ui://com.example/index.html#header")
    }

    @Test("resolveComponent returns nil for unknown selector")
    func resolveUnknown() {
        let appClass = AppClass(appId: "com.example", name: "Example")
        let uri = appClass.resolveComponent("com.example.unknown")
        #expect(uri == nil)
    }

    @Test("canHandle returns true for registered component")
    func canHandle() {
        let appClass = AppClass(appId: "com.example", name: "Example")
        appClass.addComponent("com.example.button", uri: "ui://com.example/index.html#button")
        #expect(appClass.canHandle("com.example.button"))
        #expect(!appClass.canHandle("com.example.missing"))
    }

    // MARK: - ISA chain traversal

    @Test("superclass component found when subclass lacks it")
    func isaChain() {
        let parent = AppClass(appId: "com.base", name: "Base")
        parent.addComponent("com.base.nav", uri: "ui://com.base/index.html#nav")

        let child = AppClass(appId: "com.child", name: "Child")
        child.superclass = parent

        let uri = child.resolveComponent("com.base.nav")
        #expect(uri == "ui://com.base/index.html#nav")
    }

    @Test("own dispatch table shadows superclass")
    func ownShadowsSuperclass() {
        let parent = AppClass(appId: "com.base", name: "Base")
        parent.addComponent("com.base.header", uri: "ui://com.base/index.html#header")

        let child = AppClass(appId: "com.child", name: "Child")
        child.superclass = parent
        child.addComponent("com.base.header", uri: "ui://com.child/index.html#header")

        let uri = child.resolveComponent("com.base.header")
        #expect(uri == "ui://com.child/index.html#header")
    }

    @Test("allCanonicals includes inherited selectors")
    func allCanonicalsInherited() {
        let parent = AppClass(appId: "com.base", name: "Base")
        parent.addComponent("com.base.nav", uri: "ui://com.base/index.html#nav")

        let child = AppClass(appId: "com.child", name: "Child")
        child.addComponent("com.child.footer", uri: "ui://com.child/index.html#footer")
        child.superclass = parent

        let all = child.allCanonicals()
        #expect(all.contains("com.child.footer"))
        #expect(all.contains("com.base.nav"))
    }

    // MARK: - Extension loading

    @Test("loadExtension bolts components onto class")
    func extensionLoading() {
        let appClass = AppClass(appId: "com.example", name: "Example")
        let ext = AppExtension(
            extendsAppId: "com.example",
            components: [
                ("com.example.search", "ui://com.example/index.html#search"),
                ("com.example.toolbar", "ui://com.example/index.html#toolbar"),
            ]
        )
        appClass.loadExtension(ext)

        #expect(appClass.resolveComponent("com.example.search") == "ui://com.example/index.html#search")
        #expect(appClass.resolveComponent("com.example.toolbar") == "ui://com.example/index.html#toolbar")
    }

    @Test("uiResourceUri propagated from init")
    func uiResourceUri() {
        let appClass = AppClass(appId: "com.example", name: "Example", uiResourceUri: "<html>test</html>")
        #expect(appClass.uiResourceUri == "<html>test</html>")
    }
}
