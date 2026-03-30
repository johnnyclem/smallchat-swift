import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        List(AppSection.allCases, selection: $state.selectedSection) { section in
            Label {
                Text(section.rawValue)
            } icon: {
                Image(systemName: section.icon)
            }
            .badge(badge(for: section))
        }
        .navigationTitle("SmallChat")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        #endif
    }

    private func badge(for section: AppSection) -> Text? {
        switch section {
        case .server:
            if appState.serverRunning {
                return Text("Running")
            }
            return nil
        default:
            return nil
        }
    }
}
