import SwiftUI

@main
struct StatefulTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                await model.load()
            }
        }
    }
}
