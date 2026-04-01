import Foundation
import Network

// MARK: - Hook Event

struct ClaudeHookEvent {
    let hookEventName: String
    let sessionId: String?
    let cwd: String?
    let title: String?
    let message: String?
}

// MARK: - Delegate

protocol HookSocketServerDelegate: AnyObject {
    @MainActor func hookServer(_ server: HookSocketServer, didReceive event: ClaudeHookEvent)
}

// MARK: - Server

final class HookSocketServer {
    let socketPath: String
    private var listener: NWListener?
    private weak var delegate: HookSocketServerDelegate?
    private let queue = DispatchQueue(label: "com.codespark.hook-socket", qos: .utility)

    init(delegate: HookSocketServerDelegate) {
        let pid = ProcessInfo.processInfo.processIdentifier
        self.socketPath = "/tmp/codespark-\(pid).sock"
        self.delegate = delegate
    }

    func start() throws {
        // Clean up stale socket
        unlink(socketPath)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = .unix(path: socketPath)

        listener = try NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("[HookSocketServer] listener failed: \(error)")
            }
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveAll(on: connection, accumulated: Data())
    }

    private func receiveAll(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var data = accumulated
            if let content { data.append(content) }

            if isComplete || error != nil || data.contains(UInt8(ascii: "\n")) {
                self.processMessage(data)
                connection.cancel()
            } else {
                self.receiveAll(on: connection, accumulated: data)
            }
        }
    }

    private func processMessage(_ data: Data) {
        // Trim trailing newline
        let trimmed = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        guard !trimmed.isEmpty else { return }

        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let eventName = json["hook_event_name"] as? String else { return }

        let event = ClaudeHookEvent(
            hookEventName: eventName,
            sessionId: json["session_id"] as? String,
            cwd: json["cwd"] as? String,
            title: json["title"] as? String,
            message: json["message"] as? String
        )

        let delegate = self.delegate
        let server = self
        DispatchQueue.main.async {
            delegate?.hookServer(server, didReceive: event)
        }
    }
}
