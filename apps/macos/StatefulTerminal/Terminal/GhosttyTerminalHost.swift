#if GHOSTTY_FIRST
import Foundation
import GhosttyKit

final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    private var surfaceView: GhosttyTerminalSurfaceView?
    private let app: ghostty_app_t
    private let session: SessionViewData

    init(app: ghostty_app_t, session: SessionViewData) {
        self.app = app
        self.session = session
    }

    func attach(sessionID: String) {
        surfaceView = GhosttyTerminalSurfaceView(
            app: app,
            workingDirectory: session.lastCwd,
            command: nil
        )
    }

    @MainActor
    func close(sessionID: String) {
        let snapshot: TerminalSnapshotViewData
        if let surfaceView, let surface = surfaceView.surface {
            let size = ghostty_surface_size(surface)
            snapshot = TerminalSnapshotViewData(
                cols: Int(size.columns),
                rows: Int(size.rows),
                lines: ["session closed"]
            )
        } else {
            snapshot = TerminalSnapshotViewData(cols: 80, rows: 24, lines: ["session closed"])
        }

        surfaceView = nil

        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: snapshot,
            closeReason: .userClosed
        )
    }
}
#endif
