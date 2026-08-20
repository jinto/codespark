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
        XCTAssertEqual(info.sshCommand(), "ssh localhost")

        let withUser = SSHConnectionInfo(host: "localhost", user: "testuser", port: 22)
        XCTAssertEqual(withUser.sshCommand(), "ssh -p 22 testuser@localhost")
    }

    // MARK: - Worktrees over ssh

    /// A stub can only prove the argv we built. This proves the remote shell
    /// agrees — quoting, tilde expansion, and the path git actually chose.
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
