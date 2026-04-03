import SwiftUI

@main
struct StatefulTerminalApp: App {
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                WorkspaceListView(model: model)
            } detail: {
                WorkspaceDetailView(model: model)
            }
            .frame(minWidth: 1200, minHeight: 760)
            .task {
                #if GHOSTTY_FIRST
                GhosttyRuntime.shared.initialize()
                #endif
                await model.load()
            }
        }
    }
}
