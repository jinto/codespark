import AppKit
@testable import CodeSpark

final class MockTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var shellPID: pid_t? { nil }
    var surfaceNSView: NSView? { nil }

    private(set) var initialInputs: [String?] = []
    private(set) var commands: [String?] = []

    private(set) var attachedSessionID: String?

    func attach(sessionID: String, command: String? = nil, initialInput: String? = nil) {
        attachedSessionID = sessionID
        initialInputs.append(initialInput)
        commands.append(command)
    }
    func close(sessionID: String) {}
    var viewport: TerminalSnapshotViewData?
    private(set) var restoreReads = 0

    func extractSnapshot() -> TerminalSnapshotViewData? { viewport }
    func extractRestoreSnapshot() -> TerminalSnapshotViewData? {
        restoreReads += 1
        return viewport
    }

    @MainActor
    func typeKey() {
        guard let id = attachedSessionID else { return }
        delegate?.terminalHostDidReceiveKey(sessionID: id)
    }

    @MainActor
    func finishClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        delegate?.terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
    }
}
