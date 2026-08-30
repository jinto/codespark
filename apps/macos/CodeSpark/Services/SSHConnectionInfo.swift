import Foundation

struct SSHConnectionInfo: Equatable, Hashable {
    let host: String
    var user: String?
    var port: Int?
    var remotePath: String?

    /// Parse from URI like `ssh://[user@]host[:port][/remote/path]`
    init?(uri: String) {
        guard uri.hasPrefix("ssh://") else { return nil }
        let stripped = String(uri.dropFirst("ssh://".count))
        guard !stripped.isEmpty else { return nil }

        // Split authority from path: user@host:port/path
        let authorityAndPath: (String, String?)
        if let slashIndex = stripped.firstIndex(of: "/") {
            authorityAndPath = (String(stripped[..<slashIndex]), String(stripped[slashIndex...]))
        } else {
            authorityAndPath = (stripped, nil)
        }

        let authority = authorityAndPath.0
        let pathPart = authorityAndPath.1

        // Parse user@host:port
        let userHost: (String?, String)
        if let atIndex = authority.firstIndex(of: "@") {
            let u = String(authority[..<atIndex])
            userHost = (u.isEmpty ? nil : u, String(authority[authority.index(after: atIndex)...]))
        } else {
            userHost = (nil, authority)
        }

        let hostPort = userHost.1
        if let candidate = userHost.0, !Self.isAddressable(candidate) { return nil }
        if let colonIndex = hostPort.lastIndex(of: ":") {
            let h = String(hostPort[..<colonIndex])
            let p = String(hostPort[hostPort.index(after: colonIndex)...])
            guard Self.isAddressable(h) else { return nil }
            self.host = h
            self.port = Int(p)
        } else {
            guard Self.isAddressable(hostPort) else { return nil }
            self.host = hostPort
            self.port = nil
        }

        self.user = userHost.0

        if let p = pathPart, p != "/" {
            // A URI's path component must begin with a slash, so `~/projects`
            // was stored as `/~/projects`. Read it back as what was meant, or
            // the tab tries to `cd` somewhere no machine has.
            self.remotePath = p.hasPrefix("/~") ? String(p.dropFirst()) : p
        } else {
            self.remotePath = nil
        }
    }

    init(host: String, user: String? = nil, port: Int? = nil, remotePath: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.remotePath = remotePath
    }

    var uri: String {
        var s = "ssh://"
        if let user { s += "\(user)@" }
        s += host
        if let port { s += ":\(port)" }
        if let remotePath { s += remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)" }
        return s
    }

    /// The command Ghostty runs for an ssh tab. `replay` is a shell command the
    /// remote side runs before the shell takes over — a restored tab's previous
    /// screen, which cannot be handed over as a local file.
    func sshCommand(replaying replay: String? = nil) -> String {
        var parts = ["ssh"]
        if let port { parts.append(contentsOf: ["-p", "\(port)"]) }
        // Quoted for the same reason the remote command is: Ghostty hands this
        // whole string to `/bin/sh -c`, and the host is free text from the New
        // SSH Project sheet. Unquoted, everything a `;` introduces runs here.
        parts.append("--")
        parts.append(RemoteShell.quoted(user.map { "\($0)@\(host)" } ?? host))
        if let remote = remoteCommand(replaying: replay) {
            // Ghostty runs this whole string through `/bin/sh -c`, so the remote
            // command has to survive as one word. Unquoted, the local shell eats
            // the `&&` and expands `$SHELL` here — ssh then runs a bare `cd`,
            // exits, and the tab lands in a local shell instead of the remote.
            //
            // The inner `sh -c` is the same trap one layer further out: ssh joins
            // what follows into a single string and hands it to the *remote login
            // shell*, which may be fish or csh. Neither parses the `case` the
            // reporter is built from, and today's `cd … && exec` only survived
            // there by being simple enough.
            parts.append(contentsOf: ["-t", RemoteShell.quoted("/bin/sh -c " + RemoteShell.quoted(remote))])
        }
        return parts.joined(separator: " ")
    }

    /// What a sheet shows a person: the connection and the folder it lands in.
    ///
    /// Deliberately not the literal command. That one now carries the cwd
    /// reporter's launcher, which is the same forty lines for every project and
    /// says nothing about any of them — printed under a text field it buries the
    /// host and the path, which are the only two things there to be checked.
    var previewCommand: String {
        var parts = ["ssh"]
        if let port { parts.append(contentsOf: ["-p", "\(port)"]) }
        parts.append("--")
        parts.append(RemoteShell.quoted(user.map { "\($0)@\(host)" } ?? host))
        if let remotePath {
            parts.append(contentsOf: ["-t", RemoteShell.quoted("cd \(Self.remotePathExpression(remotePath))")])
        }
        return parts.joined(separator: " ")
    }

    /// The path as the remote shell should read it. Quoting is what keeps a path
    /// with a space or an apostrophe in one piece, and it is also what stops the
    /// shell expanding a leading `~` — so the tilde is left outside the quotes
    /// and everything after it stays inside.
    static func remotePathExpression(_ path: String) -> String {
        RemoteShell.pathExpression(path)
    }

    /// What the remote `sh` runs. Internal so a test can drive it through a
    /// real zsh, bash, or fish — the reporter's failures live in shell startup
    /// order, which no comparison of command strings can see.
    func remoteCommand(replaying replay: String?) -> String? {
        var lines: [String] = []
        if let replay, !replay.isEmpty { lines.append(replay) }
        if let remotePath {
            // `|| exit` where this once read `&& exec`: the launcher that follows
            // is several lines, and `&&` would only have guarded the first of
            // them. A tab whose directory is gone still must not open a shell
            // somewhere else.
            lines.append("cd \(Self.remotePathExpression(remotePath)) || exit")
        }
        guard !lines.isEmpty else { return nil }
        lines.append(RemoteCwdReporter.launcher)
        return lines.joined(separator: "\n")
    }

    /// ssh reads *any* argv element beginning with `-` as an option, whatever
    /// position it is in, so `-oProxyCommand=…` as a host runs a command on this
    /// machine. The host is free text from the New SSH Project sheet, it is
    /// stored, and the worktree poll re-reads it every ten seconds — one bad
    /// value would fire repeatedly with nobody watching.
    ///
    /// Quoting the host, which this file already did and explained, defends the
    /// *shell*. It says nothing about the argv position, so the defence was one
    /// layer off the thing it was aimed at. A leading hyphen is refused here and
    /// the destination is separated with `--` at every call site.
    static func isAddressable(_ component: String) -> Bool {
        !component.isEmpty && !component.hasPrefix("-")
    }


    // MARK: - Workspace addressing

    /// One directory, one spelling. A trailing slash would otherwise mint a
    /// second workspace that no tab is keyed to.
    static func canonicalRemotePath(_ path: String) -> String {
        guard path != "/" else { return path }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    var displayLabel: String {
        if let user { return "\(user)@\(host)" }
        return host
    }
}

/// Teaches a remote shell to report its working directory the way a local one
/// already does.
///
/// A tab's cwd is how it finds its way back after a restart, and locally it
/// arrives by itself: the shell emits OSC 7 at every prompt and Ghostty turns
/// that into `handleSurfacePwd`. A remote shell has no such integration, so an
/// ssh tab's cwd froze at whatever directory it was opened with — `cd` on the
/// far side was lost on every restore.
///
/// Two details decide whether this works at all, and neither is guessable from
/// the outside:
///
/// - **The payload is a URI, so `$PWD` has to be encoded.** Ghostty parses OSC 7
///   with `std.Uri` and percent-decodes the path
///   (`termio/stream_handler.zig`), so a directory named `a%20b` came back as
///   `a b`, and one containing `#` or `?` came back truncated at that character
///   — the tab's cwd silently became a different directory and the next restore
///   opened that one. Ghostty's own integration encodes; this reimplementation
///   of it did not.
/// - **The hostname has to be `localhost`.** Ghostty drops any OSC 7 whose host
///   is not local (`termio/stream_handler.zig`, `os/hostname.zig`) — which is
///   exactly what a remote shell reporting its own `$HOST` would be, and why
///   simply shipping Ghostty's own integration over would report nothing.
/// - **The hook has to survive `exec $SHELL`.** A function does not cross an
///   exec, so zsh gets a startup file of ours and fish an init command. Bash's
///   `PROMPT_COMMAND` is a plain string, and a plain string crosses as an
///   environment variable — which is the only reason bash can be a login shell
///   and still report, see below.
///
/// And the shell it execs is a **login** shell. On macOS the base `PATH` is
/// assembled by `/usr/libexec/path_helper`, called from `/etc/zprofile` and
/// nowhere else, so a merely-interactive remote shell never saw
/// `/etc/paths.d/*` — `.zshrc` still aliased `vi` to `nvim` while `nvim` itself
/// was off `$PATH`. Everything a person keeps in `~/.zprofile` or
/// `~/.bash_profile`, which is where Homebrew's own instructions put it, was
/// missing for the same reason. Ghostty runs local shells through `login(1)`
/// over this exact complaint (`termio/Exec.zig`), so anything less made the two
/// halves of one app behave like two machines.
///
/// `-l` collides with each shell's injection point differently, and each answer
/// below was measured rather than reasoned:
///
/// - **zsh** reads `.zprofile` and `.zlogin` from `$ZDOTDIR` too — ours. The
///   profile gets a shim doing the same hand-back dance as `.zshenv`; `.zlogin`
///   needs none, because `.zshrc` has already returned `ZDOTDIR` to the user by
///   the time zsh looks for it.
/// - **bash** ignores `--rcfile` the moment the shell is a login shell, so the
///   hook travels in the environment instead. The cost: a startup file that
///   *assigns* `PROMPT_COMMAND` rather than appending drops the reporter — the
///   shell is fine, the cwd stops moving. A login bash also reads
///   `.bash_profile` rather than `.bashrc`, which is what every other terminal
///   on this machine does.
/// - **fish** has no conflict; `-C` runs under `-l` unchanged.
///
/// Anything unrecognised falls through to a plain interactive shell — no `-l`,
/// because `dash` rejects it and an exec that fails costs the user the terminal.
/// That is what an ssh tab did before this existed: the worst case is the old
/// behaviour.
enum RemoteCwdReporter {
    /// Where the generated startup files live on the far side. A fixed path, not
    /// a `mktemp -d`: the temporary directory can only be cleaned up by the
    /// shell that reads it, so a connection that never reaches a prompt would
    /// leave one behind on every attempt. One directory, rewritten each time.
    static let directory = #"${XDG_CACHE_HOME:-$HOME/.cache}/codespark/shell"#

    /// A POSIX `sh` script that installs the reporter and then becomes the
    /// user's shell.
    ///
    /// Written into place atomically (`mv` over a pid-suffixed file) because two
    /// tabs can connect at once, and read back before use so a home directory
    /// that cannot be written to degrades to a plain shell instead of a broken
    /// one.
    static let launcher = #"""
    __cs_s=${SHELL:-/bin/sh}
    CS_RC_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/codespark/shell; export CS_RC_DIR
    case ${__cs_s##*/} in
    zsh)
      mkdir -p "$CS_RC_DIR" 2>/dev/null && {
        CS_RC_HOME=${ZDOTDIR:-$HOME}; export CS_RC_HOME
        cat > "$CS_RC_DIR/.zshenv.$$" <<'CS_EOF' && mv -f "$CS_RC_DIR/.zshenv.$$" "$CS_RC_DIR/.zshenv"
    ZDOTDIR=$CS_RC_HOME
    [ -r "$CS_RC_HOME/.zshenv" ] && . "$CS_RC_HOME/.zshenv"
    CS_RC_HOME=$ZDOTDIR
    ZDOTDIR=$CS_RC_DIR
    CS_EOF
        cat > "$CS_RC_DIR/.zprofile.$$" <<'CS_EOF' && mv -f "$CS_RC_DIR/.zprofile.$$" "$CS_RC_DIR/.zprofile"
    ZDOTDIR=$CS_RC_HOME
    [ -r "$CS_RC_HOME/.zprofile" ] && . "$CS_RC_HOME/.zprofile"
    CS_RC_HOME=$ZDOTDIR
    ZDOTDIR=$CS_RC_DIR
    CS_EOF
        cat > "$CS_RC_DIR/.zshrc.$$" <<'CS_EOF' && mv -f "$CS_RC_DIR/.zshrc.$$" "$CS_RC_DIR/.zshrc"
    ZDOTDIR=$CS_RC_HOME
    [[ $HISTFILE == $CS_RC_DIR/* ]] && HISTFILE=$CS_RC_HOME/${HISTFILE##*/}
    [ -r "$CS_RC_HOME/.zshrc" ] && . "$CS_RC_HOME/.zshrc"
    __cs_report_pwd() {
      local p=${PWD//[%]/%25}; p=${p//[#]/%23}; p=${p//[?]/%3F}
      printf '\033]7;file://localhost%s\007' "$p"
    }
    precmd_functions+=(__cs_report_pwd)
    CS_EOF
        [ -r "$CS_RC_DIR/.zshrc" ] && [ -r "$CS_RC_DIR/.zprofile" ] && { ZDOTDIR=$CS_RC_DIR; export ZDOTDIR; }
      }
      exec "$__cs_s" -l -i
      ;;
    bash)
      PROMPT_COMMAND='__cs_p=${PWD//[%]/%25}; __cs_p=${__cs_p//[#]/%23}; __cs_p=${__cs_p//[?]/%3F}; printf "\033]7;file://localhost%s\007" "$__cs_p"'${PROMPT_COMMAND:+;$PROMPT_COMMAND}
      export PROMPT_COMMAND
      exec "$__cs_s" -l -i
      ;;
    fish)
      exec "$__cs_s" -l -i -C 'function __cs_report_pwd --on-variable PWD; set -l p (string replace -a "%" "%25" -- $PWD); set p (string replace -a "#" "%23" -- $p); set p (string replace -a "?" "%3F" -- $p); printf "\033]7;file://localhost%s\007" $p; end; __cs_report_pwd'
      ;;
    esac
    exec "$__cs_s" -i
    """#
}
