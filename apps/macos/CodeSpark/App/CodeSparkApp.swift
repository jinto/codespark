import AppKit
import ObjectiveC
import SwiftUI
import UserNotifications

@main
struct CodeSparkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel(core: WorkspaceCoreClient.live)
    @AppStorage("selectedWorkspaceID") private var savedWorkspaceID: String = ""
    @AppStorage("hiddenWorkspaceIDs") private var savedHiddenIDs: String = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    HStack(spacing: 0) {
                        SidebarView(model: model)
                            .frame(width: 240)

                        Divider()

                        MainContentView(model: model)
                    }
                    .background(AppTheme.toolbarBackground)
                    .ignoresSafeArea()
                    .task {
                        await initializeAndLoad()
                    }
                } else {
                    OnboardingView {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .preferredColorScheme(.dark)
            .frame(minWidth: 600, minHeight: 400)
            .onChange(of: model.selectedWorkspaceID) { _, newValue in
                savedWorkspaceID = newValue ?? ""
            }
            .onChange(of: model.hiddenWorkspaceIDs) { _, newValue in
                savedHiddenIDs = newValue.joined(separator: ",")
            }
        }
        .windowResizability(.contentMinSize)
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

                if !model.hiddenWorkspaceIDs.isEmpty {
                    Divider()
                    Menu("Open Recent Workspace") {
                        ForEach(Array(model.hiddenWorkspaceIDs), id: \.self) { id in
                            Button(model.hiddenWorkspaceNames[id] ?? id.prefix(8) + "...") {
                                Task { await model.reopenWorkspace(id: id) }
                            }
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button(model.activeSessionID != nil ? "Close Session" : "Close Workspace") {
                    if model.activeSessionID != nil {
                        model.pendingCloseSessionID = model.activeSessionID
                    } else if let wsID = model.selectedWorkspaceID {
                        model.pendingCloseWorkspaceID = wsID
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.selectedWorkspaceID == nil)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Reopen Closed Session") {
                    Task { await model.reopenLastClosedSession() }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.closedSessions.isEmpty)

                Divider()

                Button("Select Next Tab") {
                    model.selectNextSession()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Select Previous Tab") {
                    model.selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(Array(model.workspaces.prefix(9).enumerated()), id: \.element.id) { index, workspace in
                    Button(workspace.name) {
                        Task { await model.selectWorkspace(id: workspace.id) }
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

        Settings {
            SettingsView()
        }
    }

    @MainActor
    private func initializeAndLoad() async {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        #if GHOSTTY_FIRST
        GhosttyRuntime.shared.initialize()
        GhosttyRuntime.shared.onTerminalOutput = { [weak model] in
            model?.markActiveSessionOutput()
        }
        #endif
        appDelegate.model = model
        if !savedHiddenIDs.isEmpty {
            model.hiddenWorkspaceIDs = Set(savedHiddenIDs.split(separator: ",").map(String.init))
        }
        if !savedWorkspaceID.isEmpty {
            model.selectedWorkspaceID = savedWorkspaceID
        }
        await model.load()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Intercept Cmd+W before the system handles it
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "w" else { return event }
            self?.handleCloseShortcut()
            return nil // consume the event
        }

        // Also remove system Close menu item for good measure
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.removeSystemCloseMenuItem()
        }

        // Make content extend into the title bar area (cmux-style)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureWindowTitleBar()
        }
    }

    private func configureWindowTitleBar() {
        guard let window = NSApp.windows.first else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.setFrameAutosaveName("CodeSparkMain")
    }

    @MainActor
    private func handleCloseShortcut() {
        guard let model else { return }
        if model.activeSessionID != nil {
            model.pendingCloseSessionID = model.activeSessionID
        } else if let wsID = model.selectedWorkspaceID {
            model.pendingCloseWorkspaceID = wsID
        }
    }

    private func removeSystemCloseMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for menuItem in mainMenu.items {
            guard let submenu = menuItem.submenu else { continue }
            for item in submenu.items where item.keyEquivalent == "w" {
                submenu.removeItem(item)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
