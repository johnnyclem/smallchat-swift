import Foundation

/// Observable state for an `AppWebView` instance.
@MainActor
public final class AppViewState: ObservableObject {
    @Published public var isLoading: Bool = false
    @Published public var loadError: Error? = nil
    @Published public var currentURI: String = ""

    public init() {}
}
