import SwiftUI

@main
struct StatefulTerminalApp: App {
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)

    var body: some Scene {
        WindowGroup {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 240)

                Divider()

                MainContentView(model: model)
            }
            .background(Color(nsColor: .init(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
            .preferredColorScheme(.dark)
            .frame(minWidth: 1200, minHeight: 760)
            .task {
                #if GHOSTTY_FIRST
                GhosttyRuntime.shared.initialize()
                #endif
                await model.load()
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
