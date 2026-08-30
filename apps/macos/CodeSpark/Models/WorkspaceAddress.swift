import Foundation

/// Where a tab works — on this machine or another one — as a type rather than a
/// habit.
///
/// A workspace address is one string, and one string is what grouping,
/// selection memory, restore, and worktree removal all compare. That much is
/// deliberate. What was not deliberate is that the same `String` also carried
/// two namespaces at once: a local filesystem path and an `ssh://` URI, told
/// apart by whoever remembered to look. CLAUDE.md spends a paragraph saying
/// "두 네임스페이스를 섞지 말 것" — a sentence that should have been a type,
/// because four separate `fix:` commits were the same mistake:
///
///   `git -C 'ssh://box/srv/repo'` dies with `cannot change to`.
///   `abbreviatingWithTildeInPath` turns that URI into `ssh:/box/srv/repo`.
///   `/tmp/proj` and `/private/tmp/proj` are one directory and two workspaces,
///   and the tabs of one belong to a row nothing can select.
///
/// Here none of the three can be written. A local path is spelled one way,
/// settled once in `init`. A remote address hands out no local path at all, so
/// `git -C` cannot be given one — it takes `localPath`, and `localPath` is nil
/// for the remote arm. And the display spelling knows which it is holding.
///
/// `local` carries a `String`, not a `URL`: `URL` has spelling variance of its
/// own — trailing slashes, percent-encoding — which is the disease this type is
/// the cure for.
enum WorkspaceAddress: Hashable {
    /// A directory on this machine, symlinks resolved.
    case local(String)
    /// A directory on another machine, reached over ssh. May name no directory
    /// at all: `ssh://box` is a project whose repository nobody has located yet.
    case remote(SSHConnectionInfo)

    /// Reads an address written down anywhere — the store, UserDefaults, git's
    /// output, a project row — and settles its spelling here, once.
    init(_ raw: String) {
        if let info = SSHConnectionInfo(uri: raw) {
            self = .remote(info.canonicalized)
        } else {
            self = .local(Self.canonicalLocalPath(raw))
        }
    }

    /// The one spelling, and the only thing written back out: to the store, to
    /// UserDefaults, to `workspacePath` on a session row. Round-tripping through
    /// `init` gives the same address back.
    var storageKey: String {
        switch self {
        case .local(let path): path
        case .remote(let info): info.uri
        }
    }

    /// A directory `git -C` and the file APIs may be given — and nil whenever
    /// there is not one, which is the whole point. A path from another machine
    /// resolved against this filesystem is the confusion the type exists to end.
    var localPath: String? {
        if case .local(let path) = self { return path }
        return nil
    }

    /// The connection an address on another machine is reached through, with the
    /// directory in `remotePath`.
    var remote: SSHConnectionInfo? {
        if case .remote(let info) = self { return info }
        return nil
    }

    /// This address as it reads on screen.
    ///
    /// The host already sits on the project row, so a remote address shows the
    /// directory over there. A local one abbreviates the home directory — which
    /// is exactly what must never happen to a URI, whose `//` it eats.
    var displayName: String {
        switch self {
        case .local(let path): (path as NSString).abbreviatingWithTildeInPath
        case .remote(let info): info.remotePath ?? info.uri
        }
    }

    /// Whether `other` is this workspace or somewhere inside it.
    ///
    /// The boundary matters: `/tmp/proj-feature` starts with `/tmp/proj` and is
    /// a different worktree, so the separator is part of the test. Two addresses
    /// in different namespaces are never inside one another, whatever the text
    /// looks like.
    func contains(_ other: WorkspaceAddress) -> Bool {
        guard let mine = comparablePath, let theirs = other.comparablePath,
              sameNamespace(as: other)
        else { return false }
        return theirs == mine || theirs.hasPrefix(mine + "/")
    }

    private var comparablePath: String? {
        switch self {
        case .local(let path): path
        case .remote(let info): info.remotePath
        }
    }

    private func sameNamespace(as other: WorkspaceAddress) -> Bool {
        switch (self, other) {
        case (.local, .local): true
        case (.remote(let mine), .remote(let theirs)): mine.host == theirs.host
            && mine.user == theirs.user && mine.port == theirs.port
        default: false
        }
    }

    /// git prints the resolved directory — `/private/tmp/proj`, never
    /// `/tmp/proj` — while a project keeps whatever spelling it was added with.
    /// Two spellings are two workspaces, and the tabs of one of them end up
    /// belonging to a row nothing can select: the correction in
    /// `recomputeWorkspaces` matches and correctly leaves the selection alone,
    /// then `visibleSessions` compares and finds nothing, and the main area
    /// offers "New Terminal" over a running tab.
    ///
    /// `resolvingSymlinksInPath` only follows links that exist, and a worktree
    /// git has just reported may already be gone. `/private` is stripped
    /// explicitly because that is the pair this actually turns on — `/tmp` and
    /// `/var` are symlinks into it on every mac.
    private static func canonicalLocalPath(_ path: String) -> String {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard resolved.hasPrefix("/private/") else { return resolved }
        return String(resolved.dropFirst("/private".count))
    }
}

extension WorkspaceAddress: CustomStringConvertible {
    var description: String { storageKey }
}

extension SSHConnectionInfo {
    /// One directory, one spelling, on the far side too — a trailing slash would
    /// mint a second workspace no tab is keyed to.
    var canonicalized: SSHConnectionInfo {
        guard let path = remotePath else { return self }
        var copy = self
        copy.remotePath = Self.canonicalRemotePath(path)
        return copy
    }

    /// This connection's spelling of a remote directory.
    func address(forRemotePath remotePath: String) -> WorkspaceAddress {
        var addressed = self
        addressed.remotePath = remotePath
        return .remote(addressed.canonicalized)
    }
}
