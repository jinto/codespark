import XCTest
@testable import CodeSpark

/// Integration tests that require a running SSH server on localhost.
/// Skipped automatically when sshd is not available.
final class SSHIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            canSSHToLocalhost(),
            "sshd not running on localhost. Enable it: System Settings → General → Sharing → Remote Login"
        )
    }

    func test_ssh_localhost_connects_and_runs_command() async throws {
        let info = SSHConnectionInfo(host: "localhost")
        let output = try await runSSH(info: info, remoteCommand: "echo SSH_INTEGRATION_OK")
        XCTAssertTrue(output.contains("SSH_INTEGRATION_OK"), "Expected SSH output, got: \(output)")
    }

    func test_ssh_localhost_with_current_user() async throws {
        let currentUser = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let info = SSHConnectionInfo(host: "localhost", user: currentUser)
        let output = try await runSSH(info: info, remoteCommand: "whoami")
        XCTAssertTrue(output.contains(currentUser), "Expected \(currentUser), got: \(output)")
    }

    func test_ssh_localhost_with_remote_path() async throws {
        let info = SSHConnectionInfo(host: "localhost", remotePath: "/tmp")
        let output = try await runSSH(info: info, remoteCommand: "pwd")
        XCTAssertTrue(output.contains("/tmp"), "Expected /tmp, got: \(output)")
    }

    func test_ssh_command_builds_correctly_for_localhost() {
        let info = SSHConnectionInfo(host: "localhost")
        XCTAssertEqual(info.sshCommand(), "ssh 'localhost'")

        let withUser = SSHConnectionInfo(host: "localhost", user: "testuser", port: 22)
        XCTAssertEqual(withUser.sshCommand(), "ssh -p 22 'testuser@localhost'")
    }

    // MARK: - Worktrees over ssh

    /// A stub can only prove the argv we built. This proves the remote shell
    /// agrees — quoting, tilde expansion, and the path git actually chose.
    @MainActor
    func test_worktrees_scan_create_and_remove_over_a_real_connection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-ssh-wt-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("my repo")   // a space, on purpose
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try runLocal("/usr/bin/git", ["-C", repo.path, "init", "-q", "-b", "main"])
        try runLocal("/usr/bin/git", ["-C", repo.path, "-c", "user.email=t@t", "-c", "user.name=t",
                                      "commit", "-q", "--allow-empty", "-m", "init"])

        let projectURI = "ssh://localhost\(repo.path)"
        let worktreeRoot = root.appendingPathComponent("wt").path

        // Create
        let creation = try await GitWorktreeService.addWorktree(
            projectPath: projectURI, branch: "feat", worktreeRoot: worktreeRoot
        )
        // The address is spelled the way git spells it, which on macOS means
        // /var resolved to /private/var — so check the shape, and let the scan
        // below prove the two spellings agree.
        XCTAssertTrue(creation.path.hasPrefix("ssh://localhost/"), creation.path)
        XCTAssertTrue(creation.path.hasSuffix("/\(creation.name)"), creation.path)

        // Scan
        let service = GitWorktreeService()
        await service.refreshWorktrees(for: [projectURI])
        let found = try XCTUnwrap(service.worktrees(for: projectURI))
        XCTAssertEqual(found.count, 2, "expected the repo and its worktree, got \(found.map(\.path))")
        XCTAssertTrue(found.contains { $0.branch == "feat" && $0.path == creation.path },
                      "worktrees were \(found.map { "\($0.branch)@\($0.path)" })")

        // Remove
        try await GitWorktreeService.removeWorktree(projectPath: projectURI, worktreePath: creation.path)
        service.invalidateCache(for: projectURI)
        await service.refreshWorktrees(for: [projectURI])
        XCTAssertEqual(service.worktrees(for: projectURI)?.count, 1)
    }

    // MARK: - Remote folder picker

    func test_lists_real_directories_over_ssh() async throws {
        let root = try makeRemoteFixture(["apps", "logs"])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let listing = try await RemoteDirectoryLister().list(SSHConnectionInfo(host: "localhost"), path: root)

        XCTAssertEqual(listing.path, canonical(root))
        XCTAssertEqual(listing.entries.map(\.name), ["apps", "logs"])
    }

    func test_listing_marks_a_real_git_repository() async throws {
        let root = try makeRemoteFixture(["repo", "plain"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/repo/.git", withIntermediateDirectories: true)

        let listing = try await RemoteDirectoryLister().list(SSHConnectionInfo(host: "localhost"), path: root)

        XCTAssertEqual(listing.entries.first(where: { $0.name == "repo" })?.isGitRepository, true)
        XCTAssertEqual(listing.entries.first(where: { $0.name == "plain" })?.isGitRepository, false)
    }

    func test_listing_starts_in_the_remote_home_directory() async throws {
        let listing = try await RemoteDirectoryLister().list(SSHConnectionInfo(host: "localhost"), path: nil)

        XCTAssertEqual(listing.path, canonical(NSHomeDirectory()))
    }

    func test_a_directory_that_does_not_exist_is_reported_not_crashed() async throws {
        do {
            _ = try await RemoteDirectoryLister().list(
                SSHConnectionInfo(host: "localhost"),
                path: "/nope-\(UUID().uuidString)"
            )
            XCTFail("expected the listing to fail")
        } catch {
            XCTAssertEqual(error as? RemoteDirectoryError, .directoryUnavailable)
        }
    }

    /// `Process.waitUntilExit()` services the *current* thread's run loop, and a
    /// Swift concurrency task can resume on a different thread than the one that
    /// launched ssh — then it waits on a run loop that will never hear about the
    /// exit. It hangs on maybe one call in a handful, so one round trip proves
    /// nothing; a run of them does.
    func test_listing_returns_every_time_instead_of_hanging() async throws {
        let finished = expectation(description: "every listing returned")

        Task {
            // Concurrent, because that is what scatters the continuations across
            // the cooperative pool — a serial loop tends to resume on the very
            // thread that launched ssh and never reproduces the hang.
            for _ in 0..<5 {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            _ = try? await RemoteDirectoryLister().list(
                                SSHConnectionInfo(host: "localhost"),
                                path: "/nope-\(UUID().uuidString)"
                            )
                        }
                    }
                }
                await MainActor.run {}  // force a hop between rounds
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 60)
    }

    func test_creates_a_directory_over_ssh() async throws {
        let root = try makeRemoteFixture([])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let created = try await RemoteDirectoryLister().createDirectory(
            SSHConnectionInfo(host: "localhost"),
            in: root,
            named: "new app"
        )

        XCTAssertEqual(created, canonical(root) + "/new app")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/new app", isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The whole point of picking a folder: the tab has to open *there*.
    func test_the_picked_folder_becomes_the_session_working_directory() async throws {
        let root = try makeRemoteFixture(["apps"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picked = try await RemoteDirectoryLister()
            .list(SSHConnectionInfo(host: "localhost"), path: root + "/apps").path

        // What the sheet stores as the project path, and what the tab reopens with.
        let project = SSHConnectionInfo(host: "localhost", remotePath: picked)
        let reopened = SSHConnectionInfo(uri: project.uri)!

        let output = try await runSSH(info: reopened, remoteCommand: "pwd")
        XCTAssertTrue(output.contains(picked), "expected \(picked), got: \(output)")
    }

    /// Creates a fixture under /tmp, which localhost-ssh sees as its own filesystem.
    private func makeRemoteFixture(_ children: [String]) throws -> String {
        let root = NSTemporaryDirectory() + "cs-remote-picker-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for child in children {
            try FileManager.default.createDirectory(atPath: root + "/" + child, withIntermediateDirectories: true)
        }
        return root
    }

    /// `pwd` on the remote side resolves symlinks; /tmp is one on macOS.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Helpers

    private func runLocal(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"])
        }
    }

    private func canSSHToLocalhost() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
                             "-o", "StrictHostKeyChecking=no", "localhost", "echo", "ok"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runSSH(info: SSHConnectionInfo, remoteCommand: String) async throws -> String {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=no"]
        if let port = info.port { args.append(contentsOf: ["-p", "\(port)"]) }
        let target = info.user.map { "\($0)@\(info.host)" } ?? info.host
        args.append(target)

        if let remotePath = info.remotePath {
            args.append(contentsOf: ["-t", "cd \(remotePath) && \(remoteCommand)"])
        } else {
            args.append(remoteCommand)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let exitStatus: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
        }

        guard exitStatus == 0 else {
            throw NSError(domain: "SSHIntegration", code: Int(exitStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ssh exited with \(exitStatus)"])
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
