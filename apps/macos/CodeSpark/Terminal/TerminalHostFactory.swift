import Foundation
#if GHOSTTY_FIRST
import GhosttyKit
#endif

struct TerminalHostFactory {
    #if GHOSTTY_FIRST
    let loadGhosttyApp: () -> ghostty_app_t?
    #else
    let loadGhosttyApp: () -> UnsafeMutableRawPointer?
    #endif

    func makeHost(for session: SessionViewData) -> any TerminalHostProtocol {
        #if GHOSTTY_FIRST
        if let app = loadGhosttyApp() {
            return GhosttyTerminalHost(app: app, session: session)
        }
        #endif
        return NoOpTerminalHost()
    }
}
