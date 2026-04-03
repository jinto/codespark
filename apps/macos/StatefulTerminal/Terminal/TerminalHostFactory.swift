import Foundation

struct TerminalHostFactory {
    let loadGhosttyHandle: () -> UnsafeMutableRawPointer?

    func makeHost(for session: SessionViewData) -> any TerminalHostProtocol {
        #if GHOSTTY_FIRST
        if let handle = loadGhosttyHandle() {
            return GhosttyTerminalHost(handle: handle, session: session)
        }
        #endif
        return NoOpTerminalHost()
    }
}
