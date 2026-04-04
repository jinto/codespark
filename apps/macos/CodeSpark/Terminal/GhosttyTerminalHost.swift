#if GHOSTTY_FIRST
import Foundation
import GhosttyKit

final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? = nil
    private var surfaceView: GhosttyTerminalSurfaceView?
    private let app: ghostty_app_t
    private let session: SessionViewData

    init(app: ghostty_app_t, session: SessionViewData) {
        self.app = app
        self.session = session
    }

    func attach(sessionID: String, command: String? = nil) {
        lastOutputTime = Date()
        surfaceView = GhosttyTerminalSurfaceView(
            app: app,
            workingDirectory: session.lastCwd,
            command: command
        )
    }

    func markOutput() {
        lastOutputTime = Date()
    }

    func extractSnapshot() -> TerminalSnapshotViewData? {
        surfaceView?.extractSnapshot()
    }

    @MainActor
    func close(sessionID: String) {
        let snapshot = extractSnapshot()
            ?? TerminalSnapshotViewData(cols: 0, rows: 0, lines: [])

        surfaceView = nil

        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: snapshot,
            closeReason: .userClosed
        )
    }
}
#endif
