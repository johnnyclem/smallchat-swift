import Testing
import Foundation
#if canImport(WebKit)
import WebKit
#endif
@testable import SmallChatUI

@Suite("AppWebView")
struct AppWebViewTests {

    // MARK: - AppViewState

    @Test("AppViewState initial values")
    @MainActor func initialState() {
        let state = AppViewState()
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.currentURI.isEmpty)
    }

    // MARK: - AppWebViewSandbox (pure helper — no WKWebView needed)

#if canImport(WebKit)

    @Test("shouldAllow: matching scheme and host returns true")
    func sandboxAllowsMatchingHost() {
        let result = AppWebViewSandbox.shouldAllow(
            url: URL(string: "ui://my-app/index.html"),
            allowedURI: "ui://my-app/index.html"
        )
        #expect(result)
    }

    @Test("shouldAllow: different host returns false")
    func sandboxDeniesDifferentHost() {
        let result = AppWebViewSandbox.shouldAllow(
            url: URL(string: "https://evil.example.com/steal"),
            allowedURI: "ui://my-app/index.html"
        )
        #expect(!result)
    }

    @Test("shouldAllow: nil URL returns false")
    func sandboxDeniesNilURL() {
        let result = AppWebViewSandbox.shouldAllow(url: nil, allowedURI: "ui://my-app/index.html")
        #expect(!result)
    }

    @Test("shouldAllow: different scheme returns false")
    func sandboxDeniesDifferentScheme() {
        let result = AppWebViewSandbox.shouldAllow(
            url: URL(string: "https://my-app/index.html"),
            allowedURI: "ui://my-app/index.html"
        )
        #expect(!result)
    }

    @Test("policy: the initial about:blank document and same-origin URLs load; nothing else does")
    func policy() {
        let allowed = "ui://my-app/index.html"
        #expect(AppWebViewSandbox.policy(for: URL(string: "about:blank"), allowedURI: allowed) == .allow)
        #expect(AppWebViewSandbox.policy(for: URL(string: "ui://my-app/page2.html"), allowedURI: allowed) == .allow)
        #expect(AppWebViewSandbox.policy(for: URL(string: "https://phish.example/"), allowedURI: allowed) == .cancel)
        #expect(AppWebViewSandbox.policy(for: URL(string: "data:text/html,hi"), allowedURI: allowed) == .cancel)
    }

    /// WebKit only calls a delegate method exposed to Objective-C. A Swift
    /// signature that merely nearly matches the SDK's requirement compiles
    /// with a warning and is never called.
    @Test("WebKit can call the navigation policy on the sandbox and the view's coordinator")
    @MainActor
    func policyIsTheObjCWitness() {
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        let (_, sandbox) = AppWebViewConfiguration.make(for: "ui://my-app/index.html")
        #expect(sandbox.responds(to: selector))
        #expect(Coordinator(uiUri: "ui://my-app/index.html", state: AppViewState()).responds(to: selector))
    }

    // MARK: - AppWebViewConfiguration

    @Test("AppWebViewConfiguration produces non-nil config and sandbox")
    @MainActor
    func configurationProducedSuccessfully() {
        let (config, sandbox) = AppWebViewConfiguration.make(for: "ui://test/index.html")
        #expect(config != nil)
        #expect(sandbox.allowedURI == "ui://test/index.html")
    }

    @Test("sandbox.allowedURI propagated from make(for:)")
    @MainActor
    func sandboxAllowedURIPropagated() {
        let (_, sandbox) = AppWebViewConfiguration.make(for: "ui://my-app/index.html")
        #expect(sandbox.allowedURI == "ui://my-app/index.html")
    }

#endif
}
