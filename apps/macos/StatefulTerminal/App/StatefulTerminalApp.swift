import SwiftUI

@main
struct StatefulTerminalApp: App {
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)
    @AppStorage("selectedWorkspaceID") private var savedWorkspaceID: String = ""
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
                if !savedWorkspaceID.isEmpty {
                    model.selectedWorkspaceID = savedWorkspaceID
                }
                await model.load()
            }
            .onChange(of: model.selectedWorkspaceID) { _, newValue in
                savedWorkspaceID = newValue ?? ""
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
                    model.pendingCloseSessionID = model.activeSessionID
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

                Divider()

                ForEach(0..<min(model.workspaces.count, 9), id: \.self) { index in
                    Button(model.workspaces[index].name) {
                        Task { await model.selectWorkspace(id: model.workspaces[index].id) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.saveAllSessionsAndClose()
            }
        }
    }
}
