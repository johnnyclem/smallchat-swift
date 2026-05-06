import SwiftUI
import SmallChatUI
#if canImport(WebKit)

struct AppsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        HSplitView {
            // App list
            List(selection: $state.previewedAppURI) {
                if state.registeredApps.isEmpty {
                    ContentUnavailableView(
                        "No Apps Registered",
                        systemImage: "square.grid.2x2",
                        description: Text("Compile an app manifest to register apps here.")
                    )
                } else {
                    ForEach(state.registeredApps, id: \.id) { manifest in
                        Label(manifest.name, systemImage: "app.badge")
                            .tag(appURIFor(manifest.id))
                    }
                }
            }
            .frame(minWidth: 160, idealWidth: 200)
            .navigationTitle("Apps")

            // App preview
            if state.previewedAppURI.isEmpty {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "cursorarrow.click",
                    description: Text("Choose an app from the list to preview its UI.")
                )
            } else {
                AppWebView(
                    uiUri: state.previewedAppURI,
                    htmlContent: state.previewedAppContent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func appURIFor(_ appId: String) -> String {
        "ui://\(appId)/index.html"
    }
}

#else

struct AppsView: View {
    var body: some View {
        ContentUnavailableView(
            "WebKit Not Available",
            systemImage: "exclamationmark.triangle",
            description: Text("App previews require WebKit (macOS 14+ or iOS 17+).")
        )
    }
}

#endif
