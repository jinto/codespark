import Foundation

final class NoOpTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? { nil }

    func attach(sessionID: String, command: String? = nil) {}
    func close(sessionID: String) {}
}
