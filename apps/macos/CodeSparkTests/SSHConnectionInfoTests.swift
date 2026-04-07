import XCTest
@testable import CodeSpark

final class SSHConnectionInfoTests: XCTestCase {

    func test_parse_host_only() {
        let info = SSHConnectionInfo(uri: "ssh://myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertNil(info.port)
        XCTAssertNil(info.remotePath)
        XCTAssertEqual(info.sshCommand, "ssh myhost")
        XCTAssertEqual(info.displayLabel, "myhost")
    }

    func test_parse_user_and_host() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.sshCommand, "ssh jinto@myhost")
        XCTAssertEqual(info.displayLabel, "jinto@myhost")
    }

    func test_parse_host_and_path() {
        let info = SSHConnectionInfo(uri: "ssh://myhost/home/user/project")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertEqual(info.remotePath, "/home/user/project")
        XCTAssertEqual(info.sshCommand, "ssh myhost -t cd '/home/user/project' && exec $SHELL")
    }

    func test_parse_full_uri() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost:2222/srv/app")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.port, 2222)
        XCTAssertEqual(info.remotePath, "/srv/app")
        XCTAssertEqual(info.sshCommand, "ssh -p 2222 jinto@myhost -t cd '/srv/app' && exec $SHELL")
    }

    func test_parse_host_and_port() {
        let info = SSHConnectionInfo(uri: "ssh://myhost:8022")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.port, 8022)
        XCTAssertNil(info.user)
        XCTAssertEqual(info.sshCommand, "ssh -p 8022 myhost")
    }

    func test_uri_roundtrip() {
        let info = SSHConnectionInfo(host: "example.com", user: "deploy", port: 2222, remotePath: "/opt/app")
        XCTAssertEqual(info.uri, "ssh://deploy@example.com:2222/opt/app")
        let parsed = SSHConnectionInfo(uri: info.uri)!
        XCTAssertEqual(parsed, info)
    }

    func test_invalid_uris() {
        XCTAssertNil(SSHConnectionInfo(uri: ""))
        XCTAssertNil(SSHConnectionInfo(uri: "http://host"))
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://"))
    }

    func test_root_path_ignored() {
        let info = SSHConnectionInfo(uri: "ssh://myhost/")!
        XCTAssertNil(info.remotePath)
        XCTAssertEqual(info.sshCommand, "ssh myhost")
    }
}
