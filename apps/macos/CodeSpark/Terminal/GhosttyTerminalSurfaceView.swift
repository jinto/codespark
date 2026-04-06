#if GHOSTTY_FIRST
import AppKit
import GhosttyKit

class GhosttyTerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    // IME composition state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    init(app: ghostty_app_t, workingDirectory: String?, command: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        autoresizingMask = [.width, .height]

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        switch (workingDirectory, command) {
        case let (cwd?, cmd?):
            cwd.withCString { cwdPtr in
                cmd.withCString { cmdPtr in
                    config.working_directory = cwdPtr
                    config.command = cmdPtr
                    self.surface = ghostty_surface_new(app, &config)
                }
            }
        case let (cwd?, nil):
            cwd.withCString { cwdPtr in
                config.working_directory = cwdPtr
                self.surface = ghostty_surface_new(app, &config)
            }
        case let (nil, cmd?):
            cmd.withCString { cmdPtr in
                config.command = cmdPtr
                self.surface = ghostty_surface_new(app, &config)
            }
        case (nil, nil):
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
        guard let surface, window != nil else { return }

        let fbFrame = convertToBacking(frame)
        let xScale = fbFrame.size.width / frame.size.width
        let yScale = fbFrame.size.height / frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        syncSurfaceSize(frame.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard surface != nil else { return }
        syncSurfaceSize(newSize)
    }

    private func syncSurfaceSize(_ size: NSSize) {
        guard let surface else { return }
        let scaled = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    // MARK: - Keyboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, surface != nil else { return false }
        if event.modifierFlags.contains(.control) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedTextBefore = markedText.length > 0

        // Initialize accumulator — signals we're inside a keyDown for insertText
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let AppKit IME system process the event (Korean, Japanese, etc.)
        interpretKeyEvents([event])

        // Sync preedit state to Ghostty
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            // IME produced composed text — send each chunk
            for text in list {
                sendKeyAction(action, event: event, text: text)
            }
        } else {
            // No composed text — send the raw key event
            let text = ghosttyCharacters(for: event)
            sendKeyAction(action, event: event, text: text,
                          composing: markedText.length > 0 || markedTextBefore)
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

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        // If inside keyDown, accumulate for batch processing
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // External IME event — send directly
        guard let surface else { return }
        let data = Array(chars.utf8)
        data.withUnsafeBufferPointer { buf in
            ghostty_surface_text(surface, buf.baseAddress, UInt(buf.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default: break
        }

        // If not inside keyDown, sync preedit immediately (e.g., keyboard layout change)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange { NSRange() }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let pointInView = NSPoint(x: x, y: frame.height - y)
        let pointInWindow = convert(pointInView, to: nil)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        return NSRect(x: pointOnScreen.x, y: pointOnScreen.y - 20, width: 0, height: 20)
    }

    // MARK: - Preedit

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            markedText.string.withCString { ptr in
                let len = markedText.string.utf8.count
                ghostty_surface_preedit(surface, ptr, UInt(len))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
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
        let scrollMods: ghostty_input_scroll_mods_t = 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
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
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                                          x: UInt32(size.columns > 0 ? size.columns - 1 : 0),
                                          y: UInt32(size.rows > 0 ? size.rows - 1 : 0)),
            rectangle: false
        )
        var text = ghostty_text_s()
        let ok = ghostty_surface_read_text(surface, selection, &text)
        guard ok, let cStr = text.text, text.text_len > 0 else {
            return TerminalSnapshotViewData(cols: Int(size.columns), rows: Int(size.rows), lines: [])
        }
        let content = String(cString: cStr)
        ghostty_surface_free_text(surface, &text)
        return TerminalSnapshotViewData(cols: Int(size.columns), rows: Int(size.rows), lines: content.components(separatedBy: "\n"))
    }

    // MARK: - Helpers

    private func sendKeyAction(_ action: ghostty_input_action_e, event: NSEvent, text: String? = nil, composing: Bool = false) {
        guard let surface else { return }
        var key = makeKeyInput(event, action: action)
        key.composing = composing

        if let text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                key.text = ptr
                ghostty_surface_key(surface, key)
            }
        } else {
            ghostty_surface_key(surface, key)
        }
    }

    /// Match official Ghostty: control chars (< 0x20) → original char without Ctrl modifier
    private func ghosttyCharacters(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700, scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    private func makeKeyInput(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = translateMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        // unshifted codepoint: character without any modifiers
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            key.unshifted_codepoint = cp.value
        }
        return key
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
