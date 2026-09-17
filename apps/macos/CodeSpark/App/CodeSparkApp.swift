import AppKit
import ObjectiveC
import SwiftUI
import UserNotifications

@main
struct CodeSparkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel(
        core: ProjectCoreClient.live,
        // Through `TerminalHostFactory` rather than repeating its body: the
        // factory had tests and no production caller, and this had the same
        // decision written out a second time.
        terminalFactory: { session in
            #if GHOSTTY_FIRST
            TerminalHostFactory(loadGhosttyApp: { GhosttyRuntime.shared.app }).makeHost(for: session)
            #else
            TerminalHostFactory(loadGhosttyApp: { nil }).makeHost(for: session)
            #endif
        }
    )
    @AppStorage(StorageKeys.selectedProjectID) private var savedProjectID: String = ""
    @AppStorage(StorageKeys.hiddenProjectIDs) private var savedHiddenIDs: String = ""
    @AppStorage(StorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(StorageKeys.isSidebarVisible) private var isSidebarVisible = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    NavigationSplitView(columnVisibility: Binding(
                        get: { isSidebarVisible && !model.projects.isEmpty ? .all : .detailOnly },
                        set: { isSidebarVisible = $0 != .detailOnly }
                    )) {
                        SidebarView(model: model, onToggleSidebar: {
                            withAnimation { isSidebarVisible.toggle() }
                        })
                        .toolbar(removing: .sidebarToggle)
                        .toolbar {
                            ToolbarItemGroup(placement: .automatic) {
                                sidebarToolbarItems
                            }
                        }
                        .navigationSplitViewColumnWidth(min: 100, ideal: 120, max: 180)
                    } detail: {
                        MainContentView(model: model, onToggleSidebar: {
                            withAnimation { isSidebarVisible.toggle() }
                        })
                        .navigationTitle("\u{1F4C2} " + (model.selection.onScreen?.name ?? ""))
                        .navigationSubtitle(model.activeBranchLabel)
                    }
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
            .onChange(of: model.selection.id) { _, newValue in
                savedProjectID = newValue ?? ""
            }
            .onChange(of: model.projects.count) { _, newCount in
                if newCount > 0 { isSidebarVisible = true }
            }
            .onChange(of: model.hiddenProjectIDs) { _, newValue in
                savedHiddenIDs = newValue.joined(separator: ",")
            }
        }
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project...") {
                    model.showNewProjectSheet = true
                }
                .keyboardShortcut(.newProject)

                Divider()

                Button("New Session…") {
                    model.presentSessionChooser()
                }
                .disabled(model.selection.id == nil)
                .keyboardShortcut(.newSession)

                if !model.hiddenProjectIDs.isEmpty {
                    Divider()
                    Menu("Open Recent Project") {
                        ForEach(Array(model.hiddenProjectIDs), id: \.self) { id in
                            Button(model.hiddenProjectNames[id] ?? id.prefix(8) + "...") {
                                Task { await model.reopenProject(id: id) }
                            }
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Session") {
                    model.requestCloseFromShortcut()
                }
                .keyboardShortcut(.closeSession)
                .disabled(model.activeSessionID == nil)
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
                }
                .keyboardShortcut(.toggleSidebar)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Select Next Tab") {
                    model.selectNextSession()
                }
                .keyboardShortcut(.nextTab)

                Button("Select Previous Tab") {
                    model.selectPreviousSession()
                }
                .keyboardShortcut(.previousTab)

                Button("Select Next Worktree") {
                    model.selectNextWorktree()
                }
                .keyboardShortcut(.nextWorktree)
                .disabled(model.sidebarWorktrees.isEmpty)

                Button("Select Previous Worktree") {
                    model.selectPreviousWorktree()
                }
                .keyboardShortcut(.previousWorktree)
                .disabled(model.sidebarWorktrees.isEmpty)

                Divider()

                // Cmd+1~9: jump to a place that has tabs
                ForEach(Array(model.numberedPlaces.enumerated()), id: \.element) { index, place in
                    Button(model.numberedPlaceLabel(place)) {
                        Task { await model.selectNumberedPlace(index + 1) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: AppShortcut.selectWorkspaceByIndex.modifiers)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.saveAllSessionsForRestore()
            }
        }

        Settings {
            SettingsView()
        }
    }

    @ViewBuilder
    private var sidebarToolbarItems: some View {
        Button { withAnimation { isSidebarVisible.toggle() } } label: {
            Image(systemName: "sidebar.left")
        }
        Button { model.showNewProjectSheet = true } label: {
            Image(systemName: "plus")
        }
    }


    @MainActor
    private func initializeAndLoad() async {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        // Migrate AppStorage keys from workspace→project naming (one-time)
        if !UserDefaults.standard.bool(forKey: StorageKeys.migratedToProjectNaming) {
            for (old, new) in [
                ("selectedWorkspaceID", StorageKeys.selectedProjectID),
                ("expandedWorkspaceIDs", StorageKeys.expandedProjectIDs),
                ("hiddenWorkspaceIDs", StorageKeys.hiddenProjectIDs),
            ] {
                if let val = UserDefaults.standard.string(forKey: old), !val.isEmpty {
                    UserDefaults.standard.set(val, forKey: new)
                    UserDefaults.standard.removeObject(forKey: old)
                }
            }
            UserDefaults.standard.set(true, forKey: StorageKeys.migratedToProjectNaming)
        }

        #if GHOSTTY_FIRST
        GhosttyRuntime.shared.initialize()
        GhosttyRuntime.shared.onTerminalOutput = { [weak model] in
            model?.markActiveSessionOutput()
        }
        GhosttyRuntime.shared.onSurfaceClose = { [weak model] surfaceView, processAlive in
            model?.handleSurfaceClose(surfaceView, processAlive: processAlive)
        }
        GhosttyRuntime.shared.onSurfacePwd = { [weak model] surface, cwd in
            model?.handleSurfacePwd(surface, cwd: cwd)
        }
        #endif
        appDelegate.model = model

        // Option key held on launch → offer reset
        if NSEvent.modifierFlags.contains(.option) {
            let alert = NSAlert()
            alert.messageText = "Reset CodeSpark?"
            alert.informativeText = "This will remove all app data. Hold Option while launching to trigger this."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                hasCompletedOnboarding = false
                return
            }
        }

        if !savedHiddenIDs.isEmpty {
            model.hiddenProjectIDs = Set(savedHiddenIDs.split(separator: ",").map(String.init))
        }
        if !savedProjectID.isEmpty {
            // Named before anything is loaded — `load()` reads it to decide
            // which project to open. No detail exists yet, which is exactly
            // what a pending selection is.
            model.selection = .pending(id: savedProjectID, onScreen: nil)
        }
        await model.load()
        model.refreshAgentSessions()
    }
}

/// Where the window was when the app was last quit.
///
/// SwiftUI already autosaves the window frame — under a name that embeds the
/// *mangled type of the entire view hierarchy*. Change any view and the name
/// changes with it, so the remembered position is dropped on the next update.
/// This machine's defaults hold 35 of those keys, one per shape this app has
/// ever had, each with a position nothing will ever read again.
///
/// `setFrameAutosaveName("CodeSparkMain")` was meant to take that over and did
/// not: measured on the running app, moving the window wrote the new frame to
/// SwiftUI's key while `CodeSparkMain` kept the old one. AppKit's autosave name
/// is not ours to hold — SwiftUI owns that window.
///
/// So the frame is not left to AppKit. One key that never changes, written
/// whenever the window moves or resizes, read back at launch.
@MainActor
final class MainWindowFrame {
    nonisolated static let defaultsKey = "mainWindowFrame"

    private let defaults: UserDefaults
    private let key: String
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, key: String = MainWindowFrame.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The window the user sees, rather than merely the first one AppKit lists —
    /// `NSApp.windows` also holds panels and offscreen helpers, and its order is
    /// not something to rely on.
    static func mainWindow(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.titled) }
    }

    func restoreAndKeep(_ window: NSWindow) {
        restore(window)
        keep(window)
    }

    func restore(_ window: NSWindow) {
        guard let saved = defaults.string(forKey: key) else { return }
        let frame = NSRectFromString(saved)
        // A frame is only worth restoring if it is somewhere the user can reach.
        // Unplug the display it was saved on and this opens the window off the
        // side of the world, where the only way back is a defaults edit.
        guard frame.width > 0, frame.height > 0,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
        else { return }
        window.setFrame(frame, display: true)
    }

    /// Saves on every move and resize. Not on quit: an app that is force quit,
    /// or killed by a crash, never gets to run that code — and the position at
    /// the moment it died is the one the user wants back.
    func keep(_ window: NSWindow) {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] notification in
                guard let moved = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.save(moved) }
            }
            observers.append(token)
        }
    }

    func save(_ window: NSWindow) {
        defaults.set(NSStringFromRect(window.frame), forKey: key)
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Held for the life of the app: it owns the move/resize observers.
    private let windowFrame = MainWindowFrame()
    private var windowObserver: NSObjectProtocol?

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

        // Window title bar is configured via .windowStyle(.hiddenTitleBar) in SwiftUI Scene
        configureWindowWhenItAppears()
    }

    /// SwiftUI has not made the window yet when this runs, so there is nothing
    /// to configure and no delay that reliably says when there will be. This
    /// used to guess 0.1 seconds and lose: measured, the guess landed before the
    /// window existed, so the titlebar work was skipped and the frame was never
    /// saved — the position the user left the window in went nowhere.
    ///
    /// The window says when it is ready.
    private func configureWindowWhenItAppears() {
        if let window = MainWindowFrame.mainWindow(among: NSApp.windows) {
            configureWindowFrame(window)
            return
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  window.styleMask.contains(.titled) else { return }
            MainActor.assumeIsolated {
                self.configureWindowFrame(window)
                if let token = self.windowObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.windowObserver = nil
                }
            }
        }
    }

    private func configureWindowFrame(_ window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        // Show proxy icon (folder) permanently in titlebar
        if let proxyIcon = window.standardWindowButton(.documentIconButton) {
            proxyIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            proxyIcon.isHidden = false
        }
        windowFrame.restoreAndKeep(window)
    }

    private func handleCloseShortcut() {
        model?.requestCloseFromShortcut()
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

    func applicationWillTerminate(_ notification: Notification) {
        // scenePhase alone is not a reliable last word on quit; this one blocks
        // termination until every tab's final screen is on disk.
        MainActor.assumeIsolated { model?.saveAllSessionsForRestore() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
