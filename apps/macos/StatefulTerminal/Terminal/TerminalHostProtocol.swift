import Foundation

@MainActor
protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData)
}

protocol TerminalHostProtocol: AnyObject {
    var delegate: (any TerminalHostDelegate)? { get set }
    var lastOutputTime: Date? { get }
    func attach(sessionID: String, command: String?)
    func close(sessionID: String)
}
