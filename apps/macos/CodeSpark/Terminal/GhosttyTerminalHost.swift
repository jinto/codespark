#if GHOSTTY_FIRST
import AppKit
import Darwin
import GhosttyKit

final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    private(set) var _shellPID: pid_t?
    /// Returns shellPID only if the shell process is still alive.
    /// Guards against PID recycling — if the surface reports process exited, skip Level 1.
    var shellPID: pid_t? {
        guard let pid = _shellPID,
              let surface = surfaceView?.surface,
              !ghostty_surface_process_exited(surface) else { return nil }
        return Self.shell(startedBy: pid)
    }

    /// Ghostty starts every tab through `login(1)`, which waits on what it
    /// started — so the PID we catch is login's, and it always has a child.
    /// Read as the shell, every local tab looked busy forever: never idle,
    /// and the screen never got read.
    static func shell(startedBy pid: pid_t) -> pid_t {
        // `proc_name` can't read login: it runs as root. The process table can.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              withUnsafeBytes(of: info.kp_proc.p_comm, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "login"
        else { return pid }
        return TerminalStateDetector.childPIDs(of: pid).first ?? pid
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

    func attach(sessionID: String, command: String? = nil, initialInput: String? = nil) {
        let beforePIDs = Set(TerminalStateDetector.childPIDs(of: getpid()))
        let sv = GhosttyTerminalSurfaceView(
            app: app,
            workingDirectory: session.lastCwd,
            command: command,
            initialInput: initialInput,
            environment: Self.terminalEnvironment()
        )
        let afterPIDs = Set(TerminalStateDetector.childPIDs(of: getpid()))
        _shellPID = afterPIDs.subtracting(beforePIDs).first
        sv.sshConnectionInfo = sshConnectionInfo
        sv.onKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.delegate?.terminalHostDidReceiveKey(sessionID: sessionID) }
        }
        surfaceView = sv
    }

    static func terminalEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []

        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        paths.insert(contentsOf: commonPaths, at: 0)

        let nvmRoot = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil
        ) {
            paths.insert(
                contentsOf: versions.map { $0.appendingPathComponent("bin").path },
                at: commonPaths.count
            )
        }

        var uniquePaths: [String] = []
        var seen = Set<String>()
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            uniquePaths.append(path)
        }
        return [
            "PATH": uniquePaths.joined(separator: ":"),
            // Ghostty will not inject its integration into Apple's /bin/bash,
            // so on such a login shell OSC 7 never fires and every restore
            // opens the project folder. Bash reads PROMPT_COMMAND straight from
            // the environment — it survives `login -flp` and `exec -l` — and
            // zsh/fish never look at it. Same accepted cost as the ssh
            // reporter: a dotfile that *assigns* PROMPT_COMMAND drops it.
            "PROMPT_COMMAND": RemoteCwdReporter.bashPromptCommand,
        ]
    }

    /// List direct child PIDs of the given process.
    func extractSnapshot() -> TerminalSnapshotViewData? {
        surfaceView?.extractSnapshot()
    }

    func extractRestoreSnapshot() -> TerminalSnapshotViewData? {
        surfaceView?.extractSnapshot(includingScrollbackPages: 10)
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
