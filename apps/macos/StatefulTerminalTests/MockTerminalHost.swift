import Foundation
@testable import StatefulTerminal

final class MockTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? { nil }

    func attach(sessionID: String, command: String? = nil) {}
    func close(sessionID: String) {}
    func extractSnapshot() -> TerminalSnapshotViewData? { nil }

    @MainActor
    func finishClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        delegate?.terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
    }
}
