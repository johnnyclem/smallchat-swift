import Testing
import Foundation
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

    // MARK: - AppWebViewConfiguration

    @Test("AppWebViewConfiguration produces non-nil config and sandbox")
    func configurationProducedSuccessfully() {
        let (config, sandbox) = AppWebViewConfiguration.make(for: "ui://test/index.html")
        #expect(config != nil)
        #expect(sandbox.allowedURI == "ui://test/index.html")
    }

    @Test("sandbox.allowedURI propagated from make(for:)")
    func sandboxAllowedURIPropagated() {
        let (_, sandbox) = AppWebViewConfiguration.make(for: "ui://my-app/index.html")
        #expect(sandbox.allowedURI == "ui://my-app/index.html")
    }

#endif
}
