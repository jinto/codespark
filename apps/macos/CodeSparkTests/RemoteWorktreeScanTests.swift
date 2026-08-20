import XCTest
@testable import CodeSpark

/// Remote worktree lookups, driven through a stub `ssh` so they run without a
/// server. The stub records its argv and prints canned porcelain output.
final class RemoteWorktreeScanTests: XCTestCase {

    private var stubDirectory: URL!
    private var originalSSHPath: String!

    override func setUpWithError() throws {
        originalSSHPath = GitWorktreeService.sshExecutablePath
        stubDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-remote-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        GitWorktreeService.sshExecutablePath = originalSSHPath
        try? FileManager.default.removeItem(at: stubDirectory)
    }

    /// Installs a stub at `<tmp>/ssh` that writes its argv to `argv.txt` and
    /// prints `stdout`, then points the service at it.
    @discardableResult
    private func installStubSSH(stdout: String, exitCode: Int = 0) throws -> URL {
        let argvFile = stubDirectory.appendingPathComponent("argv.txt")
        let stub = stubDirectory.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > '\(argvFile.path)'
        cat <<'STUB_EOF'
        \(stdout)
        STUB_EOF
        exit \(exitCode)
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        GitWorktreeService.sshExecutablePath = stub.path
        return argvFile
    }

    private func recordedArgv(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - argv

    func test_remote_lookup_never_prompts_for_a_password() {
        let info = SSHConnectionInfo(host: "box")
        let argv = GitWorktreeService.remoteSSHArguments(info, remoteCommand: "true")
        XCTAssertTrue(argv.contains("BatchMode=yes"), "argv was \(argv)")
        XCTAssertTrue(argv.contains("ConnectTimeout=5"), "argv was \(argv)")
    }

    func test_remote_lookup_carries_user_and_port() throws {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222)
        let argv = GitWorktreeService.remoteSSHArguments(info, remoteCommand: "true")
        XCTAssertTrue(argv.contains("jay@box"), "argv was \(argv)")
        let portIndex = try XCTUnwrap(argv.firstIndex(of: "-p"))
        XCTAssertEqual(argv[portIndex + 1], "2222")
    }

    /// The remote side runs this through a shell, so a path with a space or an
    /// apostrophe has to survive as one word — a comparison of command strings
    /// would never catch this.
    func test_repo_path_survives_the_remote_shell_as_one_word() {
        let command = GitWorktreeService.remoteWorktreeListCommand(repoPath: "/srv/it's here")
        XCTAssertEqual(command, "git -C '/srv/it'\\''s here' worktree list --porcelain")
    }

    // MARK: - Scanning

    func test_remote_worktrees_come_back_addressed_as_uris() async throws {
        try installStubSSH(stdout: """
        worktree /srv/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /srv/wt/repo-feat-ab12
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat
        """)

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://jay@box/srv/repo"])

        let worktrees = try XCTUnwrap(service.worktrees(for: "ssh://jay@box/srv/repo"))
        XCTAssertEqual(worktrees.map(\.path), [
            "ssh://jay@box/srv/repo",
            "ssh://jay@box/srv/wt/repo-feat-ab12",
        ])
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feat"])
        XCTAssertTrue(worktrees[0].isMainWorktree)
    }

    func test_the_scan_asks_the_right_host_for_the_right_repo() async throws {
        let argvFile = try installStubSSH(stdout: """
        worktree /srv/repo
        branch refs/heads/main
        """)

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://jay@box:2222/srv/repo"])

        let argv = try recordedArgv(argvFile)
        XCTAssertTrue(argv.contains("jay@box"), "argv was \(argv)")
        XCTAssertTrue(argv.contains("git -C '/srv/repo' worktree list --porcelain"), "argv was \(argv)")
    }

    /// Without a remote path there is no way to know where the repository is,
    /// and guessing costs a connection on every poll.
    func test_a_project_without_a_remote_path_is_not_scanned() async throws {
        let argvFile = try installStubSSH(stdout: "")

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://box"])

        XCTAssertNil(service.worktrees(for: "ssh://box"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: argvFile.path), "ssh should not have run")
    }

    // MARK: - Concurrency

    /// One slow host must not hold up the others, but neither should every
    /// project on the list spawn an ssh at once.
    func test_lookups_run_no_more_than_four_at_a_time() async throws {
        let liveDirectory = stubDirectory.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        let peakFile = stubDirectory.appendingPathComponent("peak.txt")
        let stub = stubDirectory.appendingPathComponent("ssh")
        // Each run drops a marker file, records the high-water count, sleeps,
        // then clears its marker. A directory listing is the live count.
        let script = """
        #!/bin/sh
        mine='\(liveDirectory.path)'/$$
        : > "$mine"
        live=$(ls '\(liveDirectory.path)' | wc -l | tr -d ' ')
        peak=$(cat '\(peakFile.path)' 2>/dev/null || echo 0)
        if [ "$live" -gt "$peak" ]; then printf '%s' "$live" > '\(peakFile.path)'; fi
        sleep 0.5
        rm -f "$mine"
        echo 'worktree /srv/repo'
        echo 'branch refs/heads/main'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        GitWorktreeService.sshExecutablePath = stub.path

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: (1...8).map { "ssh://box/srv/repo\($0)" })

        let peakText = try String(contentsOf: peakFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let peak = Int(peakText) ?? 0
        XCTAssertGreaterThan(peak, 0, "the stub never ran")
        XCTAssertLessThanOrEqual(peak, 4, "ran \(peak) ssh processes at once")
    }
}
