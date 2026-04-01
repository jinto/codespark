import AppKit

@MainActor
protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData)
}

protocol TerminalHostProtocol: AnyObject {
    var delegate: (any TerminalHostDelegate)? { get set }
    var lastOutputTime: Date? { get }
    /// The underlying NSView for display — nil for NoOp hosts.
    var surfaceNSView: NSView? { get }
    func markOutput()
    func attach(sessionID: String, command: String?)
    func close(sessionID: String)
    func extractSnapshot() -> TerminalSnapshotViewData?
}
