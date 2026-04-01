#if GHOSTTY_FIRST
import AppKit
import GhosttyKit
import os

@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    /// Called on main thread when Ghostty processes terminal output (wakeup → tick).
    var onTerminalOutput: (() -> Void)?

    /// Called on main thread when Ghostty requests a surface close (process exit or close action).
    /// Parameters: the surface view that should close, and whether the process is still alive.
    var onSurfaceClose: ((GhosttyTerminalSurfaceView, Bool) -> Void)?

    /// Coalesces wakeup signals: skip dispatch if a tick is already queued.
    /// Uses os_unfair_lock for thread-safe access from Ghostty's C runtime thread.
    private let tickLock = OSAllocatedUnfairLock(initialState: false)

    deinit {
        if let app {
            ghostty_app_free(app)
        }
    }

    func initialize() {
        guard app == nil else { return }
        // Skip Ghostty initialization in unit test environment
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Must call ghostty_init before any other API
        let initResult = ghostty_init(0, nil)
        guard initResult == 0 else {
            NSLog("GhosttyRuntime: ghostty_init failed with code \(initResult)")
            return
        }

        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }

        // Apply font settings via temp config file
        let fontConfig = TerminalFontSettings.buildConfigString()
        let tempPath = NSTemporaryDirectory() + "codespark-ghostty-\(ProcessInfo.processInfo.processIdentifier).conf"
        try? fontConfig.write(toFile: tempPath, atomically: true, encoding: .utf8)
        tempPath.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let rt = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                let alreadyPending = rt.tickLock.withLock { pending -> Bool in
                    if pending { return true }
                    pending = true
                    return false
                }
                guard !alreadyPending else { return }
                DispatchQueue.main.async {
                    guard let app = rt.app else {
                        rt.tickLock.withLock { $0 = false }
                        return
                    }
                    ghostty_app_tick(app)
                    rt.onTerminalOutput?()
                    // Yield one run-loop pass before allowing the next tick,
                    // so user events (Cmd+Tab, mouse) aren't starved by heavy output.
                    RunLoop.main.perform { rt.tickLock.withLock { $0 = false } }
                }
            },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, loc, content, len, _ in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return }
                guard let content, len > 0 else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                // content is an array of ghostty_clipboard_content_s
                let first = content.pointee
                if let data = first.data {
                    pasteboard.setString(String(cString: data), forType: .string)
                }
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                let surfaceView = Unmanaged<GhosttyTerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.onSurfaceClose?(surfaceView, processAlive)
                }
            }
        )

        app = ghostty_app_new(&runtime, config)
        if app == nil {
            NSLog("GhosttyRuntime: ghostty_app_new failed")
        }
    }
}
#endif
