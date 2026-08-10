import AppKit
@testable import CodeSpark

final class MockTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? { nil }
    var shellPID: pid_t? { nil }
    var surfaceNSView: NSView? { nil }

    func markOutput() {}
    private(set) var initialInputs: [String?] = []

    func attach(sessionID: String, command: String? = nil, initialInput: String? = nil) {
        initialInputs.append(initialInput)
    }
    func close(sessionID: String) {}
    func extractSnapshot() -> TerminalSnapshotViewData? { nil }

    @MainActor
    func finishClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        delegate?.terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
    }
}
