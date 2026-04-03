#if GHOSTTY_FIRST
import AppKit
import GhosttyKit

class GhosttyTerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?

    init(app: ghostty_app_t, workingDirectory: String?, command: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.isOpaque = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        if let cwd = workingDirectory {
            cwd.withCString { ptr in
                config.working_directory = ptr
                self.surface = ghostty_surface_new(app, &config)
            }
        } else {
            surface = ghostty_surface_new(app, &config)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface, let window {
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        ghostty_surface_set_size(surface, UInt32(newSize.width), UInt32(newSize.height))
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Cmd+V: paste from system clipboard
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            if let str = NSPasteboard.general.string(forType: .string) {
                let data = Array(str.utf8)
                data.withUnsafeBufferPointer { buf in
                    ghostty_surface_text(surface, buf.baseAddress, UInt(buf.count))
                }
            }
            return
        }

        if let chars = event.characters, !chars.isEmpty {
            chars.withCString { ptr in
                var key = makeKeyInput(event, action: GHOSTTY_ACTION_PRESS)
                key.text = ptr
                ghostty_surface_key(surface, key)
            }
        } else {
            let key = makeKeyInput(event, action: GHOSTTY_ACTION_PRESS)
            ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key = makeKeyInput(event, action: GHOSTTY_ACTION_RELEASE)
        ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        let key = makeKeyInput(event, action: GHOSTTY_ACTION_PRESS)
        ghostty_surface_key(surface, key)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, translateMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // ghostty_input_scroll_mods_t is a packed int32
        let scrollMods: ghostty_input_scroll_mods_t = 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Snapshot

    func extractSnapshot() -> TerminalSnapshotViewData {
        guard let surface else {
            return TerminalSnapshotViewData(cols: 0, rows: 0, lines: [])
        }

        let size = ghostty_surface_size(surface)

        // Read the entire viewport
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: UInt32(size.columns > 0 ? size.columns - 1 : 0),
                y: UInt32(size.rows > 0 ? size.rows - 1 : 0)
            ),
            rectangle: false
        )

        var text = ghostty_text_s()
        let ok = ghostty_surface_read_text(surface, selection, &text)
        guard ok, let cStr = text.text, text.text_len > 0 else {
            return TerminalSnapshotViewData(cols: Int(size.columns), rows: Int(size.rows), lines: [])
        }

        let content = String(cString: cStr)
        ghostty_surface_free_text(surface, &text)

        let lines = content.components(separatedBy: "\n")
        return TerminalSnapshotViewData(cols: Int(size.columns), rows: Int(size.rows), lines: lines)
    }

    // MARK: - Helpers

    private func makeKeyInput(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        ghostty_input_key_s(
            action: action,
            mods: translateMods(event.modifierFlags),
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )
    }

    private func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        return ghostty_input_mods_e(rawValue: raw)
    }
}
#endif
