import AppKit

@MainActor
protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData)
    /// Someone typed into the tab — the answer to whatever it was asking.
    func terminalHostDidReceiveKey(sessionID: String)
}

protocol TerminalHostProtocol: AnyObject {
    var delegate: (any TerminalHostDelegate)? { get set }
    /// The shell process ID for this terminal session — nil for NoOp hosts or if PID capture failed.
    var shellPID: pid_t? { get }
    /// The underlying NSView for display — nil for NoOp hosts.
    var surfaceNSView: NSView? { get }
    func attach(sessionID: String, command: String?, initialInput: String?)
    func close(sessionID: String)
    func extractSnapshot() -> TerminalSnapshotViewData?
    /// What restore replays: the screen plus recent scrollback, so a restored
    /// tab can be scrolled back through, not just the last screenful.
    /// Ghostty can't read a slice of scrollback, so this reads all of it and
    /// trims — ~20ms a full tab, under the renderer lock. Checkpoints only
    /// call it for tabs whose live screen changed.
    func extractRestoreSnapshot() -> TerminalSnapshotViewData?
}

extension TerminalHostProtocol {
    func extractRestoreSnapshot() -> TerminalSnapshotViewData? { extractSnapshot() }
}
