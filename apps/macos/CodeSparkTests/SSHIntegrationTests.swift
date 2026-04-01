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
        XCTAssertEqual(info.sshCommand, "ssh localhost")

        let withUser = SSHConnectionInfo(host: "localhost", user: "testuser", port: 22)
        XCTAssertEqual(withUser.sshCommand, "ssh -p 22 testuser@localhost")
    }

    // MARK: - Helpers

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
