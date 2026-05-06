#if canImport(WebKit)
import WebKit

// MARK: - AppWebViewSandbox

/// Navigation delegate that sandboxes a `WKWebView` to a single allowed URI.
///
/// Equivalent to the HTML `iframe sandbox="allow-scripts allow-same-origin"` attribute
/// used by the TypeScript `AppView` component.
///
/// - Scripts are enabled (default WKWebView behaviour).
/// - Any navigation whose host/scheme differs from `allowedURI` is cancelled.
/// - A CSP `<meta>` tag is injected at document start to restrict resource loading
///   to the same origin.
public final class AppWebViewSandbox: NSObject, WKNavigationDelegate, @unchecked Sendable {
    public let allowedURI: String

    public init(allowedURI: String) {
        self.allowedURI = allowedURI
    }

    // MARK: - Pure helper (testable without WKWebView)

    /// Returns `true` when navigation to `url` should be allowed given `allowedURI`.
    public static func shouldAllow(url: URL?, allowedURI: String) -> Bool {
        guard let url else { return false }
        guard let allowed = URL(string: allowedURI) else { return false }
        // Allow same scheme + host; nil host (e.g. about:blank) is denied
        return url.scheme == allowed.scheme && url.host == allowed.host
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Always allow the initial HTML load (no URL, or data: scheme)
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let allowed = Self.shouldAllow(url: url, allowedURI: allowedURI)
        decisionHandler(allowed ? .allow : .cancel)
    }
}

// MARK: - AppWebViewConfiguration

public enum AppWebViewConfiguration {
    /// Build a sandboxed `WKWebViewConfiguration` for the given `allowedURI`.
    ///
    /// Returns both the configuration and the `AppWebViewSandbox` so the caller
    /// can hold a strong reference to the delegate (WKWebView holds it weakly).
    public static func make(for allowedURI: String) -> (WKWebViewConfiguration, AppWebViewSandbox) {
        let config = WKWebViewConfiguration()

        // Inject CSP to restrict resource loading to same origin
        let cspScript = WKUserScript(
            source: """
            var meta = document.createElement('meta');
            meta.httpEquiv = 'Content-Security-Policy';
            meta.content = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'";
            document.head.appendChild(meta);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cspScript)

        // One process pool per configuration → process isolation
        config.processPool = WKProcessPool()

        let sandbox = AppWebViewSandbox(allowedURI: allowedURI)
        return (config, sandbox)
    }
}
#endif
