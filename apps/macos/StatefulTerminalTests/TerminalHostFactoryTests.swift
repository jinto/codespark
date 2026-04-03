import XCTest
@testable import StatefulTerminal

final class TerminalHostFactoryTests: XCTestCase {
    func test_factory_falls_back_to_noop_host_when_ghostty_is_unavailable() {
        let factory = TerminalHostFactory(loadGhosttyApp: { nil })
        let host = factory.makeHost(for: SessionViewData.fixture())
        XCTAssertTrue(host is NoOpTerminalHost)
    }
}
