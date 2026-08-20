import XCTest
@testable import CodeSpark

final class SSHConnectionInfoTests: XCTestCase {

    func test_parse_host_only() {
        let info = SSHConnectionInfo(uri: "ssh://myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertNil(info.port)
        XCTAssertNil(info.remotePath)
        XCTAssertEqual(info.sshCommand(), "ssh 'myhost'")
        XCTAssertEqual(info.displayLabel, "myhost")
    }

    func test_parse_user_and_host() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.sshCommand(), "ssh 'jinto@myhost'")
        XCTAssertEqual(info.displayLabel, "jinto@myhost")
    }

    func test_parse_host_and_path() {
        let info = SSHConnectionInfo(uri: "ssh://myhost/home/user/project")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertEqual(info.remotePath, "/home/user/project")
        XCTAssertEqual(info.sshCommand(), "ssh 'myhost' -t 'cd '\\''/home/user/project'\\'' && exec $SHELL'")
    }

    func test_parse_full_uri() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost:2222/srv/app")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.port, 2222)
        XCTAssertEqual(info.remotePath, "/srv/app")
        XCTAssertEqual(info.sshCommand(), "ssh -p 2222 'jinto@myhost' -t 'cd '\\''/srv/app'\\'' && exec $SHELL'")
    }

    func test_parse_host_and_port() {
        let info = SSHConnectionInfo(uri: "ssh://myhost:8022")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.port, 8022)
        XCTAssertNil(info.user)
        XCTAssertEqual(info.sshCommand(), "ssh -p 8022 'myhost'")
    }

    func test_uri_roundtrip() {
        let info = SSHConnectionInfo(host: "example.com", user: "deploy", port: 2222, remotePath: "/opt/app")
        XCTAssertEqual(info.uri, "ssh://deploy@example.com:2222/opt/app")
        let parsed = SSHConnectionInfo(uri: info.uri)!
        XCTAssertEqual(parsed, info)
    }

    func test_invalid_uris() {
        XCTAssertNil(SSHConnectionInfo(uri: ""))
        XCTAssertNil(SSHConnectionInfo(uri: "http://host"))
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://"))
    }

    func test_root_path_ignored() {
        let info = SSHConnectionInfo(uri: "ssh://myhost/")!
        XCTAssertNil(info.remotePath)
        XCTAssertEqual(info.sshCommand(), "ssh 'myhost'")
    }

    // MARK: - What ssh actually receives
    //
    // Ghostty runs a surface command through `/bin/sh -c` (embedded.zig sets
    // `config.command = .{ .shell = cmd }`), so asserting the command *string*
    // proves nothing: the local shell parses it first. These tests run the
    // string through a real `/bin/sh` with a stub `ssh` and check the argv.

    func test_the_remote_command_reaches_ssh_as_a_single_argument() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost/srv/app")!
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand()),
            ["myhost", "-t", "cd '/srv/app' && exec $SHELL"]
        )
    }

    func test_a_replay_rides_along_inside_the_remote_command() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost/srv/app")!
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand(replaying: "printf '%b' 'screen'")),
            ["myhost", "-t", "printf '%b' 'screen'; cd '/srv/app' && exec $SHELL"]
        )
    }

    func test_a_replay_opens_a_shell_even_without_a_remote_path() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost")!
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand(replaying: "printf '%b' 'screen'")),
            ["myhost", "-t", "printf '%b' 'screen'; exec $SHELL"]
        )
    }

    /// The host comes from a free-text field in the New SSH Project sheet, and
    /// the whole command is parsed by the local `/bin/sh` before ssh ever sees
    /// it. Unquoted, everything after a `;` runs on this machine.
    func test_a_host_with_a_shell_metacharacter_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "box; touch /tmp/codespark-should-not-exist",
                                     remotePath: "/srv/app")
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand()),
            ["box; touch /tmp/codespark-should-not-exist", "-t", "cd '/srv/app' && exec $SHELL"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/codespark-should-not-exist"),
                       "the local shell ran what was typed into the host field")
    }

    func test_a_user_with_a_shell_metacharacter_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "box", user: "jay$(id -u)", remotePath: "/srv/app")
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand()),
            ["jay$(id -u)@box", "-t", "cd '/srv/app' && exec $SHELL"]
        )
    }

    func test_a_remote_path_with_a_quote_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "myhost", remotePath: "/srv/it's here")
        XCTAssertEqual(
            try argumentsSSHReceives(from: info.sshCommand()),
            ["myhost", "-t", "cd '/srv/it'\\''s here' && exec $SHELL"]
        )
    }

    /// Runs `command` the way Ghostty does and returns the argv a stub `ssh`
    /// sees. `SHELL` is set to a marker so local expansion is detectable.
    private func argumentsSSHReceives(from command: String) throws -> [String] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-ssh-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorded = directory.appendingPathComponent("argv")
        let stub = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument" >> '\(recorded.path)'; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": directory.path, "SHELL": "/local/shell"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let text = (try? String(contentsOf: recorded, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Workspace addressing

    // A worktree on the other machine has to be addressable in the same string
    // space as the project itself — `workspacePath` is one column, and it is
    // what grouping, selection, restore, and removal all compare.

    func test_workspace_uri_carries_the_connection_authority() {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222, remotePath: "/srv/repo")
        XCTAssertEqual(
            info.workspaceURI(forRemotePath: "/srv/worktrees/repo-feat-ab12"),
            "ssh://jay@box:2222/srv/worktrees/repo-feat-ab12"
        )
    }

    func test_workspace_uri_round_trips_to_the_remote_path() {
        let info = SSHConnectionInfo(host: "box", remotePath: "/srv/repo")
        let uri = info.workspaceURI(forRemotePath: "/srv/wt/a b")
        XCTAssertEqual(SSHConnectionInfo.remotePath(fromWorkspaceURI: uri), "/srv/wt/a b")
    }

    // A local workspace path answers nil, which is how callers tell the two
    // namespaces apart without a second flag.
    func test_local_paths_have_no_remote_path() {
        XCTAssertNil(SSHConnectionInfo.remotePath(fromWorkspaceURI: "/Users/jay/projects/codespark"))
    }

    // Two spellings of one directory would be two different workspaces, and a
    // tab keyed to the wrong spelling answers to no row at all.
    func test_trailing_slash_is_not_a_different_worktree() {
        let info = SSHConnectionInfo(host: "box")
        XCTAssertEqual(
            info.workspaceURI(forRemotePath: "/srv/wt/repo/"),
            info.workspaceURI(forRemotePath: "/srv/wt/repo")
        )
    }

    func test_root_survives_canonicalization() {
        XCTAssertEqual(SSHConnectionInfo.canonicalRemotePath("/"), "/")
    }

    func test_shell_quoting_survives_an_apostrophe() {
        XCTAssertEqual(SSHConnectionInfo.shellQuoted("/srv/it's here"), "'/srv/it'\\''s here'")
    }
}
