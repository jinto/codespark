import AppKit

final class NoOpTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? { nil }
    var shellPID: pid_t? { nil }
    var surfaceNSView: NSView? { nil }

    func markOutput() {}
    func attach(sessionID: String, command: String? = nil) {}
    @MainActor
    func close(sessionID: String) {
        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: TerminalSnapshotViewData(cols: 0, rows: 0, lines: []),
            closeReason: .userClosed
        )
    }
    func extractSnapshot() -> TerminalSnapshotViewData? { nil }
}
