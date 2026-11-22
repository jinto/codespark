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
    /// Close, escape one, reopen — for the quote, and for the backslash too.
    /// POSIX single quotes take a backslash literally, but the far login shell
    /// may be fish, which reads `\'` and `\\` as escapes even inside them: a
    /// quoted-twice `'` (a path inside the remote command) left fish an
    /// unterminated string and the tab died. Outside quotes `\\` means one
    /// backslash to sh, bash, zsh, fish and csh alike.
    static func quoted(_ value: String) -> String {
        "'" + value.map { $0 == "'" ? #"'\''"# : $0 == "\\" ? #"'\\'"# : String($0) }.joined() + "'"
    }

    /// The word ssh hands the far side to run `script` under `/bin/sh`.
    ///
    /// sshd runs it with the user's *login shell*, which is not ours to pick:
    /// csh rejects a newline inside quotes and expands `!` even inside them,
    /// xonsh rejects a nested `'\''`, fish reads backslashes inside them. A
    /// quoted script only survives the shells that parse quotes like sh. So the
    /// script crosses as base64 — letters, digits, `+/=` — and nothing in this
    /// word is special to any of them. `-D` is the decode flag of older macOS.
    static func posixCommand(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return #"/bin/sh -c 'd=\#(encoded); eval "$(printf %s "$d" | base64 -d 2>/dev/null || printf %s "$d" | base64 -D)"'"#
    }

    /// Flags for a login, interactive `$SHELL -c` — as a POSIX `sh` word.
    /// csh takes `-l` only as its sole flag, so it gets `-ic` (its `.cshrc`
    /// runs for every shell anyway). The patterns open with `(`: bash 3.2 (the
    /// `/bin/sh` of macOS) misparses a bare `pat)` inside `$(…)`.
    static let loginInteractiveFlags = #"$(case ${SHELL##*/} in (*csh) echo -ic;; (*) echo -lic;; esac)"#

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
