import Foundation
import GhosttyKit

#if GHOSTTY_FIRST
final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    private var surface: ghostty_surface_t?
    private let session: SessionViewData

    init(app: ghostty_app_t, session: SessionViewData) {
        self.session = session
    }

    func attach(sessionID: String) {
        // Phase 2: wire ghostty_surface_new here
    }

    @MainActor
    func close(sessionID: String) {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        delegate?.terminalHostDidClose(
            sessionID: sessionID,
            snapshot: TerminalSnapshotViewData(cols: 80, rows: 24, lines: ["ghostty session closed"]),
            closeReason: .userClosed
        )
    }
}
#endif
