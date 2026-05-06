import SwiftUI

#if canImport(WebKit)
import WebKit

// MARK: - AppWebView

/// SwiftUI view that displays App UI content in a sandboxed `WKWebView`.
///
/// Equivalent to the TypeScript React `AppView` component with an
/// `<iframe sandbox="allow-scripts allow-same-origin">` attribute.
///
/// The view:
/// - Loads `htmlContent` via `WKWebView.loadHTMLString(_:baseURL:)`.
/// - Sandboxes navigation to `uiUri` using `AppWebViewSandbox`.
/// - Shows a `ProgressView` overlay while loading.
public struct AppWebView: View {
    public let uiUri: String
    public let htmlContent: String
    @StateObject private var state = AppViewState()

    public init(uiUri: String, htmlContent: String) {
        self.uiUri = uiUri
        self.htmlContent = htmlContent
    }

    public var body: some View {
        _AppWebViewRepresentable(uiUri: uiUri, htmlContent: htmlContent, state: state)
            .overlay {
                if state.isLoading {
                    ProgressView()
                }
            }
    }
}

// MARK: - Platform Representable

#if os(macOS)
struct _AppWebViewRepresentable: NSViewRepresentable {
    let uiUri: String
    let htmlContent: String
    @ObservedObject var state: AppViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(uiUri: uiUri, state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        let (config, sandbox) = AppWebViewConfiguration.make(for: uiUri)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.sandbox = sandbox
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(webView, html: htmlContent, uri: uiUri)
    }
}
#elseif os(iOS)
struct _AppWebViewRepresentable: UIViewRepresentable {
    let uiUri: String
    let htmlContent: String
    @ObservedObject var state: AppViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(uiUri: uiUri, state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let (config, sandbox) = AppWebViewConfiguration.make(for: uiUri)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.sandbox = sandbox
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(webView, html: htmlContent, uri: uiUri)
    }
}
#endif

// MARK: - Coordinator

final class Coordinator: NSObject, WKNavigationDelegate, @unchecked Sendable {
    let uiUri: String
    let state: AppViewState
    var sandbox: AppWebViewSandbox?
    private var loadedHTML: String?

    init(uiUri: String, state: AppViewState) {
        self.uiUri = uiUri
        self.state = state
    }

    func loadIfNeeded(_ webView: WKWebView, html: String, uri: String) {
        guard html != loadedHTML else { return }
        loadedHTML = html
        Task { @MainActor in state.isLoading = true }
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            state.isLoading = false
            state.currentURI = uiUri
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            state.isLoading = false
            state.loadError = error
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        sandbox?.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
            ?? decisionHandler(.allow)
    }
}

#endif
