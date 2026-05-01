import SwiftUI

@main
struct SmallChatAppMain: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif

        #if os(macOS)
        Settings {
            SettingsPlaceholder()
        }
        #endif
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.selectedSection {
            case .compiler:
                CompilerView()
            case .server:
                ServerView()
            case .manifest:
                ManifestEditorView()
            case .inspector:
                InspectorView()
            case .resolver:
                ResolverView()
            case .discovery:
                DiscoveryView()
            case .refinement:
                RefinementView()
            case .doctor:
                DoctorView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct SettingsPlaceholder: View {
    var body: some View {
        Text("SmallChat Settings")
            .padding(40)
    }
}
