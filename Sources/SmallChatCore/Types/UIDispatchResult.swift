/// UIDispatchResult -- the outcome of `AppRuntime.uiDispatch(_:args:)`.
///
/// Always returned (never thrown) so callers can branch without try/catch.
/// `.notFound` covers both "no matching app" and any internal error.
public enum UIDispatchResult: Sendable {
    case resolved(appId: String, uri: String, content: String)
    case notFound
}
