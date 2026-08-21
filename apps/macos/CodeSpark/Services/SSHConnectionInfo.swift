import Foundation

struct SSHConnectionInfo: Equatable {
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
        if let colonIndex = hostPort.lastIndex(of: ":") {
            let h = String(hostPort[..<colonIndex])
            let p = String(hostPort[hostPort.index(after: colonIndex)...])
            guard !h.isEmpty else { return nil }
            self.host = h
            self.port = Int(p)
        } else {
            guard !hostPort.isEmpty else { return nil }
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
        parts.append(Self.shellQuoted(user.map { "\($0)@\(host)" } ?? host))
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
            parts.append(contentsOf: ["-t", Self.shellQuoted("/bin/sh -c " + Self.shellQuoted(remote))])
        }
        return parts.joined(separator: " ")
    }

    /// The path as the remote shell should read it. Quoting is what keeps a path
    /// with a space or an apostrophe in one piece, and it is also what stops the
    /// shell expanding a leading `~` — so the tilde is left outside the quotes
    /// and everything after it stays inside.
    static func remotePathExpression(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + shellQuoted(String(path.dropFirst(2)))
        }
        return shellQuoted(path)
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

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Workspace addressing

    /// This connection's spelling of a remote directory, for use as a
    /// `workspacePath`.
    ///
    /// A tab's workspace is one string, and that one string is what grouping,
    /// selection memory, restore, and worktree removal all compare. Remote
    /// worktrees join the same string space as the project URI rather than
    /// getting a namespace of their own, so none of that machinery has to learn
    /// about hosts.
    func workspaceURI(forRemotePath remotePath: String) -> String {
        var addressed = self
        addressed.remotePath = Self.canonicalRemotePath(remotePath)
        return addressed.uri
    }

    /// The remote directory inside a workspace address, or nil when the address
    /// is a local filesystem path. The nil is the caller's cue about which
    /// namespace it is holding — remote paths must never reach local file APIs,
    /// and URIs must never reach `git -C`.
    static func remotePath(fromWorkspaceURI uri: String) -> String? {
        SSHConnectionInfo(uri: uri)?.remotePath
    }

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
/// - **The hostname has to be `localhost`.** Ghostty drops any OSC 7 whose host
///   is not local (`termio/stream_handler.zig`, `os/hostname.zig`) — which is
///   exactly what a remote shell reporting its own `$HOST` would be, and why
///   simply shipping Ghostty's own integration over would report nothing.
/// - **The hook has to survive `exec $SHELL`.** Functions and prompt hooks do
///   not cross an exec, so each shell gets a startup file of ours instead.
///
/// Anything unrecognised falls through to a plain shell, which is what an ssh
/// tab did before this existed — the worst case is the old behaviour.
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
        cat > "$CS_RC_DIR/.zshrc.$$" <<'CS_EOF' && mv -f "$CS_RC_DIR/.zshrc.$$" "$CS_RC_DIR/.zshrc"
    ZDOTDIR=$CS_RC_HOME
    [[ $HISTFILE == $CS_RC_DIR/* ]] && HISTFILE=$CS_RC_HOME/${HISTFILE##*/}
    [ -r "$CS_RC_HOME/.zshrc" ] && . "$CS_RC_HOME/.zshrc"
    __cs_report_pwd() { printf '\033]7;file://localhost%s\007' "$PWD"; }
    precmd_functions+=(__cs_report_pwd)
    CS_EOF
        [ -r "$CS_RC_DIR/.zshrc" ] && { ZDOTDIR=$CS_RC_DIR; export ZDOTDIR; }
      }
      ;;
    bash)
      mkdir -p "$CS_RC_DIR" 2>/dev/null && {
        cat > "$CS_RC_DIR/bashrc.$$" <<'CS_EOF' && mv -f "$CS_RC_DIR/bashrc.$$" "$CS_RC_DIR/bashrc"
    [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    __cs_report_pwd() { printf '\033]7;file://localhost%s\007' "$PWD"; }
    PROMPT_COMMAND="__cs_report_pwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    CS_EOF
        [ -r "$CS_RC_DIR/bashrc" ] && exec "$__cs_s" --rcfile "$CS_RC_DIR/bashrc" -i
      }
      ;;
    fish)
      exec "$__cs_s" -i -C 'function __cs_report_pwd --on-variable PWD; printf "\033]7;file://localhost%s\007" $PWD; end; __cs_report_pwd'
      ;;
    esac
    exec "$__cs_s" -i
    """#
}
