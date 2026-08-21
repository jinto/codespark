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
            parts.append(contentsOf: ["-t", Self.shellQuoted(remote)])
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

    private func remoteCommand(replaying replay: String?) -> String? {
        var steps: [String] = []
        if let replay, !replay.isEmpty { steps.append("\(replay); ") }
        if let remotePath { steps.append("cd \(Self.remotePathExpression(remotePath)) && ") }
        guard !steps.isEmpty else { return nil }
        return steps.joined() + "exec $SHELL"
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
