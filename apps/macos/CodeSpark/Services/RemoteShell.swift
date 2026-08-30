import Foundation

/// Everything this app knows about handing text to a shell on the far side.
///
/// Both of these existed three times over, byte for byte, in
/// `SSHConnectionInfo`, `RemoteDirectoryLister`, `GitWorktreeService` and
/// `RestoredScreenReplay`. That is the shape of duplication that matters most:
/// this is the boundary where a directory name becomes shell syntax, so a
/// correction reaching one copy and not the others is a hole that looks fixed.
///
/// The copies had already started to drift elsewhere in the same family — the
/// two ssh option blocks disagree about `ConnectTimeout` with nothing recording
/// which number was meant — so this is one home, and a test refuses new ones.
enum RemoteShell {

    /// One shell word, whatever is in it.
    ///
    /// Single quotes take everything literally, so the only character needing
    /// care is the quote itself: close, escape one, reopen.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path as the *remote* shell should read it.
    ///
    /// A leading `~` is the one part we want expanded over there, so it is left
    /// outside the quotes as `"$HOME"` and everything after it goes inside.
    /// Quoting the whole thing instead would land the tab in a directory
    /// literally named `~`; leaving the whole thing bare would let `$(…)` in a
    /// directory name run on the remote host.
    static func pathExpression(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + quoted(String(path.dropFirst(2)))
        }
        return quoted(path)
    }
}
