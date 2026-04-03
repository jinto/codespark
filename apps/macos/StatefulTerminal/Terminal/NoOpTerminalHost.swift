import Foundation

final class NoOpTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?

    func attach(sessionID: String) {}
    func close(sessionID: String) {}
}
