import SwiftUI
import SmallChatAgents

@main
struct SmallChatAppMain: App {
    @State private var appState = AppState()
    @State private var messenger = SmallChatAppMain.makeMessenger()

    var body: some Scene {
        WindowGroup {
            MessengerRootView()
                .environment(messenger)
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif

        #if os(macOS)
        Settings {
            MessengerSettingsView()
                .environment(messenger)
        }
        #endif
    }

    @MainActor
    static func makeMessenger() -> MessengerModel {
        let store = MessengerStore(url: MessengerStore.defaultURL())
        let settings = store.load().settings
        return MessengerModel(
            store: store,
            transport: AgentTransports.make(settings: settings),
            scanner: ClaudeSessionScanner()
        )
    }
}
