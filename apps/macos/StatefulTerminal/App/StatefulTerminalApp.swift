import SwiftUI

@main
struct StatefulTerminalApp: App {
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 240)

                Divider()

                MainContentView(model: model)
            }
            .background(AppTheme.toolbarBackground)
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    Task { await model.createWorkspace(name: "New Workspace") }
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("New Session") {
                    Task { await model.newSession() }
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("Close Session") {
                    if let id = model.activeSessionID {
                        model.closeSession(id: id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.activeSessionID == nil)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Select Next Tab") {
                    model.selectNextSession()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Select Previous Tab") {
                    model.selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.saveAllSessionsAndClose()
            }
        }
    }
}
