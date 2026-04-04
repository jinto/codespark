#if GHOSTTY_FIRST
import AppKit
import GhosttyKit

@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

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

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                DispatchQueue.main.async {
                    guard let userdata else { return }
                    let rt = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                    guard let app = rt.app else { return }
                    ghostty_app_tick(app)
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
            close_surface_cb: { _, _ in
                // Surface close is handled by GhosttyTerminalHost
            }
        )

        app = ghostty_app_new(&runtime, config)
        if app == nil {
            NSLog("GhosttyRuntime: ghostty_app_new failed")
        }
    }
}
#endif
