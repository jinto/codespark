import Foundation

#if GHOSTTY_FIRST
final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    private let handle: UnsafeMutableRawPointer
    private let session: SessionViewData

    init(handle: UnsafeMutableRawPointer, session: SessionViewData) {
        self.handle = handle
        self.session = session
    }

    func attach(sessionID: String) {
        // Ghostty surface attach — wired when SDK symbols are available
    }

    func close(sessionID: String) {
        // Ghostty surface close — wired when SDK symbols are available
        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: TerminalSnapshotViewData(cols: 80, rows: 24, lines: ["ghostty session closed"]),
            closeReason: .userClosed
        )
    }
}
#endif
