import Foundation
@testable import StatefulTerminal

final class MockTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?

    func attach(sessionID: String) {}
    func close(sessionID: String) {}

    @MainActor
    func finishClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        delegate?.terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
    }
}
