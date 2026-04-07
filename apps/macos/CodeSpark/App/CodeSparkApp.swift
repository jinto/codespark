import AppKit
import ObjectiveC
import SwiftUI
import UserNotifications

@main
struct CodeSparkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel(core: ProjectCoreClient.live)
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
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
                    } detail: {
                        MainContentView(model: model, onToggleSidebar: {
                            withAnimation { isSidebarVisible.toggle() }
                        })
                        .navigationTitle("\u{1F4C2} " + (model.selectedProject?.name ?? ""))
                        .navigationSubtitle(model.workspaces.first(where: { $0.path == model.selectedWorkspacePath })?.branch ?? "")
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
            .onChange(of: model.selectedProjectID) { _, newValue in
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
                Button("New Project") {
                    Task { await model.createProjectFromFolder() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("New Session") {
                    Task { await model.newSession() }
                }
                .keyboardShortcut("t", modifiers: .command)

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
                Button(model.activeSessionID != nil ? "Close Session" : "Close Project") {
                    if model.activeSessionID != nil {
                        model.pendingCloseSessionID = model.activeSessionID
                    } else if let projID = model.selectedProjectID {
                        model.pendingCloseProjectID = projID
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.selectedProjectID == nil)
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
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

                ForEach(Array(model.projects.prefix(9).enumerated()), id: \.element.id) { index, project in
                    Button(project.name) {
                        Task { await model.selectProject(id: project.id) }
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

    @ViewBuilder
    private var sidebarToolbarItems: some View {
        Button { withAnimation { isSidebarVisible.toggle() } } label: {
            Image(systemName: "sidebar.left")
        }
        Button { Task { await model.createProjectFromFolder() } } label: {
            Image(systemName: "plus")
        }
    }

    @ViewBuilder
    private var projectToolbarItems: some View {
        if let project = model.selectedProject {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                if let ws = model.workspaces.first(where: { $0.path == model.selectedWorkspacePath }) {
                    Text("›")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(ws.branch)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
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

        // Start hook socket server for Claude Code integration
        let hookServer = HookSocketServer(delegate: model)
        do {
            try hookServer.start()
            model.hookServer = hookServer
            setenv("CODESPARK_SOCK", hookServer.socketPath, 1)
        } catch {
            NSLog("[CodeSpark] Hook server failed to start: \(error)")
        }

        // Add bundled CLI tools to PATH so child processes can find codespark-hook
        if let binDir = Bundle.main.url(forResource: "bin", withExtension: nil)?.path {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            setenv("PATH", "\(binDir):\(currentPath)", 1)
        }

        #if GHOSTTY_FIRST
        GhosttyRuntime.shared.initialize()
        GhosttyRuntime.shared.onTerminalOutput = { [weak model] in
            model?.markActiveSessionOutput()
        }
        #endif
        appDelegate.model = model
        if !savedHiddenIDs.isEmpty {
            model.hiddenProjectIDs = Set(savedHiddenIDs.split(separator: ",").map(String.init))
        }
        if !savedProjectID.isEmpty {
            model.selectedProjectID = savedProjectID
        }
        await model.load()
        model.checkClaudeHooksHealth()
        if model.claudeHooksStatus != .installed {
            model.installClaudeHooks()
        }
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

        // Window title bar is configured via .windowStyle(.hiddenTitleBar) in SwiftUI Scene
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureWindowFrame()
        }
    }

    private func configureWindowFrame() {
        guard let window = NSApp.windows.first else { return }
        window.titlebarSeparatorStyle = .none
        // Show proxy icon (folder) permanently in titlebar
        if let proxyIcon = window.standardWindowButton(.documentIconButton) {
            proxyIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            proxyIcon.isHidden = false
        }
        window.setFrameAutosaveName("CodeSparkMain")
    }

    @MainActor
    private func handleCloseShortcut() {
        guard let model else { return }
        if model.activeSessionID != nil {
            model.pendingCloseSessionID = model.activeSessionID
        } else if let projID = model.selectedProjectID {
            model.pendingCloseProjectID = projID
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

    func applicationWillTerminate(_ notification: Notification) {
        model?.hookServer?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct HideToolbarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
