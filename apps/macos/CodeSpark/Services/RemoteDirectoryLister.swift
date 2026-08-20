import Foundation

struct RemoteDirectoryEntry: Equatable, Identifiable {
    let name: String
    let isGitRepository: Bool

    var id: String { name }
    var isHidden: Bool { name.hasPrefix(".") }
}

struct RemoteDirectoryListing: Equatable {
    /// Where the remote shell says it ended up — `~` and `..` already resolved.
    let path: String
    let entries: [RemoteDirectoryEntry]
}

enum RemoteDirectoryError: Error, Equatable {
    /// ssh itself gave up: unknown host, refused key, password prompt suppressed.
    case connectionFailed(String)
    case directoryUnavailable
    case createFailed(String)
    case commandFailed(code: Int32, message: String)
    case malformedOutput
}

extension RemoteDirectoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return message
        case .directoryUnavailable: return "Can't open that folder."
        case .createFailed(let message): return message
        case .commandFailed(let code, let message):
            return message.isEmpty ? "The remote shell exited with \(code)." : message
        case .malformedOutput: return "The host answered with something unreadable."
        }
    }
}

/// What the folder picker needs from a host — narrow enough that a test can be one.
protocol RemoteDirectorySource: Sendable {
    func listDirectory(at path: String?) async throws -> RemoteDirectoryListing
    func createDirectory(in parent: String, named name: String) async throws -> String
}

/// One ssh host, ready to be browsed.
struct SSHDirectorySource: RemoteDirectorySource {
    let info: SSHConnectionInfo

    func listDirectory(at path: String?) async throws -> RemoteDirectoryListing {
        try await RemoteDirectoryLister().list(info, path: path)
    }

    func createDirectory(in parent: String, named name: String) async throws -> String {
        try await RemoteDirectoryLister().createDirectory(info, in: parent, named: name)
    }
}

/// Lists directories on an ssh host so the folder picker has something to show.
///
/// Everything the remote side runs is assembled here as one `/bin/sh` script and
/// handed to ssh as a single word: ssh joins its trailing arguments with spaces
/// and the remote *login* shell parses them again, so an unquoted script loses
/// its `;` and `$e` over there — the same trap `SSHConnectionInfo.sshCommand()`
/// documents for the local side.
final class RemoteDirectoryLister: @unchecked Sendable {
    /// Printed right before the payload so a chatty `.bashrc` can't be mistaken
    /// for the directory we landed in.
    static let marker = "__CODESPARK_LS__"

    // MARK: - Building the question

    static func listScript(path: String?) -> String {
        let target = path.map(remoteExpression(for:)) ?? "\"$HOME\""
        return """
        cd -- \(target) 2>/dev/null || exit 3
        printf "%s\\n" \(shellQuoted(marker))
        pwd
        for e in * .*; do
        [ -d "$e" ] || continue
        case "$e" in .|..) continue;; esac
        if [ -e "$e/.git" ]; then printf "g\\t%s\\n" "$e"; else printf "d\\t%s\\n" "$e"; fi
        done
        """
    }

    static func createScript(in parent: String, named name: String) -> String {
        let quotedName = shellQuoted(name)
        return """
        cd -- \(remoteExpression(for: parent)) 2>/dev/null || exit 3
        mkdir -- \(quotedName) || exit 4
        printf "%s\\n" \(shellQuoted(marker))
        cd -- \(quotedName) && pwd
        """
    }

    /// A path as the remote shell should read it. Only a leading `~` is left to
    /// that shell to expand — everything else is quoted so it stays a path.
    static func remoteExpression(for path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + shellQuoted(String(path.dropFirst(2)))
        }
        return shellQuoted(path)
    }

    static func arguments(for info: SSHConnectionInfo, script: String) -> [String] {
        var args = [
            "-o", "BatchMode=yes",           // never stall the picker on a prompt
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
        ]
        if let port = info.port { args.append(contentsOf: ["-p", "\(port)"]) }
        args.append(info.user.map { "\($0)@\(info.host)" } ?? info.host)
        args.append(contentsOf: ["/bin/sh", "-c", shellQuoted(script)])
        return args
    }

    // MARK: - Reading the answer

    static func parseListing(_ stdout: String) throws -> RemoteDirectoryListing {
        let lines = stdout.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(of: marker) else {
            throw RemoteDirectoryError.malformedOutput
        }
        var rest = lines[lines.index(after: markerIndex)...].makeIterator()
        guard let path = rest.next()?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            throw RemoteDirectoryError.malformedOutput
        }

        var entries: [RemoteDirectoryEntry] = []
        while let line = rest.next() {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[line.index(after: tab)...])
            guard !name.isEmpty else { continue }
            entries.append(RemoteDirectoryEntry(name: name, isGitRepository: line[..<tab] == "g"))
        }

        return RemoteDirectoryListing(
            path: path,
            entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    /// The only line after the marker — where a freshly created folder landed.
    static func parsePath(_ stdout: String) throws -> String {
        let lines = stdout.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(of: marker),
              let path = lines[lines.index(after: markerIndex)...].first?
                  .trimmingCharacters(in: .whitespaces),
              !path.isEmpty
        else {
            throw RemoteDirectoryError.malformedOutput
        }
        return path
    }

    static func failure(exitCode: Int32, stderr: String) -> RemoteDirectoryError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case 255:
            return .connectionFailed(message.isEmpty ? "Could not reach the host." : message)
        case 3:
            return .directoryUnavailable
        case 4:
            return .createFailed(message.isEmpty ? "Could not create the folder." : message)
        default:
            return .commandFailed(code: exitCode, message: message)
        }
    }

    // MARK: - Paths

    static func isValidFolderName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !name.contains("/"), !name.contains("\n") else { return false }
        return name != "." && name != ".."
    }

    static func parentPath(of path: String) -> String? {
        guard path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - Running it

    func list(_ info: SSHConnectionInfo, path: String?) async throws -> RemoteDirectoryListing {
        let stdout = try await run(info, script: Self.listScript(path: path))
        return try Self.parseListing(stdout)
    }

    /// Returns the canonical path of the folder that was created.
    func createDirectory(_ info: SSHConnectionInfo, in parent: String, named name: String) async throws -> String {
        guard Self.isValidFolderName(name) else {
            throw RemoteDirectoryError.createFailed("\"\(name)\" is not a folder name.")
        }
        let stdout = try await run(info, script: Self.createScript(in: parent, named: name))
        return try Self.parsePath(stdout)
    }

    private func run(_ info: SSHConnectionInfo, script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: info, script: script)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Both pipes have to drain while ssh is still running: a host with a long
        // banner fills the stderr buffer and deadlocks a stdout-first read.
        async let outData = Self.readToEnd(out)
        async let errData = Self.readToEnd(err)

        let status: Int32
        do {
            status = try await Self.exitStatus(of: process)
        } catch {
            // Nothing was spawned, so nothing will ever close the write ends and
            // the two readers above would wait for an EOF that never comes.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            _ = await (outData, errData)
            throw RemoteDirectoryError.connectionFailed(error.localizedDescription)
        }

        let (stdout, stderr) = await (outData, errData)
        guard status == 0 else {
            throw Self.failure(
                exitCode: status,
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    /// Launches ssh and waits for it the only way that is safe here.
    ///
    /// `Process.waitUntilExit()` spins the *calling thread's* run loop, and an
    /// `await` can resume this function on a different thread of the cooperative
    /// pool than the one that launched ssh — that run loop never hears about the
    /// exit and the call hangs forever, long after ssh is gone. The termination
    /// handler is installed before `run()` so an instant exit cannot slip past.
    private static func exitStatus(of process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
