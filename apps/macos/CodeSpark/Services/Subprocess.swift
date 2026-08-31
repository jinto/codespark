import Foundation

/// The one way this app spawns a child process.
///
/// There were seven spawn sites and four different answers to "how do we wait
/// for it", two of which were wrong in ways the codebase had already diagnosed
/// and fixed *somewhere else*:
///
/// - **Drain both pipes at once.** A stdout-first read deadlocks the moment the
///   child fills the 64KB stderr buffer — and one of our own remote scripts
///   deliberately sends `git worktree add`'s progress to stderr, so the
///   chattiest command was the one being read second.
/// - **Install the termination handler before `run()`.** `waitUntilExit()` spins
///   the *calling thread's* run loop, and an `await` can resume on a different
///   thread of the cooperative pool than the one that launched the child; that
///   run loop never hears the exit. Installing the handler after the child has
///   already exited is the same bet from the other side — Foundation is not
///   obliged to call a handler set that late, and one lost continuation froze
///   every later worktree refresh for the life of the app, because they queue
///   behind one another.
/// - **Always have a deadline.** Only the remote paths had one. A `git` blocked
///   on `index.lock` wedged the same queue with no way out.
enum Subprocess {

    struct Result {
        var stdout: Data
        var stderr: Data
        var status: Int32

        var out: String { String(data: stdout, encoding: .utf8) ?? "" }
        var err: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    enum Failure: Error, LocalizedError {
        case couldNotLaunch(String)
        case timedOut(seconds: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .couldNotLaunch(let why): why
            case .timedOut(let seconds): "Timed out after \(Int(seconds))s"
            }
        }
    }

    /// Runs a command to completion and hands back everything it said.
    ///
    /// Callers that do not care about one of the streams simply ignore it;
    /// draining both is not optional, it is what keeps the child from blocking.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        currentDirectory: String? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        async let outData = readToEnd(out)
        async let errData = readToEnd(err)

        // A flag rather than the task's value: awaiting the deadline to find out
        // whether it fired would wait out the whole timeout on every successful
        // run.
        let expired = Expired()
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                expired.set()
                process.terminate()
            }
        }
        defer { deadline.cancel() }

        let status: Int32
        do {
            status = try await exitStatus(of: process)
        } catch {
            // Nothing was spawned, so nothing will ever close the write ends and
            // the two readers above would wait for an EOF that never comes.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            _ = await (outData, errData)
            throw Failure.couldNotLaunch(error.localizedDescription)
        }

        let result = Result(stdout: await outData, stderr: await errData, status: status)
        // A terminated child still reports a status, so the only way to tell a
        // timeout from an ordinary failure is whether the deadline is what
        // ended it.
        if expired.value { throw Failure.timedOut(seconds: timeout) }
        return result
    }

    /// Set on the deadline's thread, read on the caller's.
    private final class Expired: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// The handler goes on before `run()`, so an instant exit cannot slip past.
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

    /// Off the cooperative pool: `readDataToEndOfFile` blocks, and the pool has
    /// one thread per core to spend.
    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }
}
