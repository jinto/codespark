import Foundation

/// The `xterm-ghostty` terminfo, as base64 source ready to plant on a remote
/// box (`RemoteCwdReporter.terminfoInstaller`).
///
/// The compiled database in the bundle can't cross the wire — it is built for
/// the local ncurses and keyed by machine — so we hand the far side *source*
/// and let its own `tic` compile it. `infocmp -x` turns the bundled compiled
/// entry back into source; base64 removes every quoting hazard on the way
/// through `/bin/sh -c`, ssh, and `printf`.
///
/// Read once and cached: the entry is fixed for the life of the app version,
/// and it is read from the bundle we just shipped it in (`Resources/terminfo`),
/// so it does not depend on whatever terminfo the developer's machine happens
/// to have.
enum RemoteTerminfo {
    static let bundledSourceBase64: String? = load()

    // Not `Subprocess.run`, which the repo otherwise standardises on: that is
    // `async` with a deadline, and this is a `static let` initializer with no
    // async context to await in. The async-deadlock class that rule guards
    // against (`waitUntilExit` resuming on a different thread after an `await`)
    // cannot arise here — it is straight-line synchronous, no `await`. And the
    // work can't wedge on anything external: `infocmp -A <bundle>` reads a file
    // we shipped, no network, no locks. A deadline is still wired below so a
    // pathological `infocmp` can never hang the first ssh open.
    private static func load() -> String? {
        guard let terminfoDir = Bundle.main.resourceURL?
            .appendingPathComponent("terminfo", isDirectory: true),
              FileManager.default.fileExists(atPath: terminfoDir.path)
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        // `-A <dir>` reads our bundled db specifically, not the machine's.
        process.arguments = ["-A", terminfoDir.path, "-x", "xterm-ghostty"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Reading a local compiled entry is effectively instant; the deadline is
        // only there so a wedged process can't freeze the caller forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data.base64EncodedString()
    }
}
