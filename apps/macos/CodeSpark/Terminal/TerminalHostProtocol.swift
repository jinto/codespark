import AppKit

@MainActor
protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData)
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
}
