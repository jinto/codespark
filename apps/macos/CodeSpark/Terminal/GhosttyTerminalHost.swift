#if GHOSTTY_FIRST
import AppKit
import Darwin
import GhosttyKit

final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? = nil
    private(set) var _shellPID: pid_t?
    /// Returns shellPID only if the shell process is still alive.
    /// Guards against PID recycling — if the surface reports process exited, skip Level 1.
    var shellPID: pid_t? {
        guard let pid = _shellPID,
              let surface = surfaceView?.surface,
              !ghostty_surface_process_exited(surface) else { return nil }
        return pid
    }
    private(set) var surfaceView: GhosttyTerminalSurfaceView?
    var surfaceNSView: NSView? { surfaceView }
    private let app: ghostty_app_t
    private let session: SessionViewData

    var sshConnectionInfo: SSHConnectionInfo?

    init(app: ghostty_app_t, session: SessionViewData) {
        self.app = app
        self.session = session
    }

    func attach(sessionID: String, command: String? = nil) {
        lastOutputTime = Date()
        let beforePIDs = Set(Self.childPIDs(of: getpid()))
        let sv = GhosttyTerminalSurfaceView(
            app: app,
            workingDirectory: session.lastCwd,
            command: command
        )
        let afterPIDs = Set(Self.childPIDs(of: getpid()))
        _shellPID = afterPIDs.subtracting(beforePIDs).first
        sv.sshConnectionInfo = sshConnectionInfo
        surfaceView = sv
    }

    /// List direct child PIDs of the given process.
    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let estSize = proc_listchildpids(parent, nil, 0)
        guard estSize > 0 else { return [] }
        let count = Int(estSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actualSize = proc_listchildpids(parent, &pids, estSize)
        guard actualSize > 0 else { return [] }
        return Array(pids.prefix(Int(actualSize) / MemoryLayout<pid_t>.size))
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
