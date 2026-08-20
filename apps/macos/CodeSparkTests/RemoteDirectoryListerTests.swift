import XCTest
@testable import CodeSpark

/// The remote folder picker never gets to see a filesystem — it sees the bytes
/// one `ssh` run printed. These tests pin down that seam: what we ask the remote
/// shell to run, and what we believe when it answers.
final class RemoteDirectoryListerTests: XCTestCase {

    // MARK: - Reading the answer

    func test_listing_reports_the_canonical_path_and_its_directories() throws {
        let listing = try RemoteDirectoryLister.parseListing("""
        \(RemoteDirectoryLister.marker)
        /home/deploy
        d\tapps
        d\tlogs
        """)

        XCTAssertEqual(listing.path, "/home/deploy")
        XCTAssertEqual(listing.entries.map(\.name), ["apps", "logs"])
    }

    func test_listing_flags_git_repositories() throws {
        let listing = try RemoteDirectoryLister.parseListing("""
        \(RemoteDirectoryLister.marker)
        /srv
        g\tcodespark
        d\tscratch
        """)

        XCTAssertEqual(listing.entries.first(where: { $0.name == "codespark" })?.isGitRepository, true)
        XCTAssertEqual(listing.entries.first(where: { $0.name == "scratch" })?.isGitRepository, false)
    }

    /// A chatty `.bashrc` prints before our script ever runs. Taking the first
    /// line as the path would make the picker land in "Welcome to prod!".
    func test_listing_ignores_anything_printed_before_the_marker() throws {
        let listing = try RemoteDirectoryLister.parseListing("""
        Welcome to prod!
        You have mail.
        \(RemoteDirectoryLister.marker)
        /root
        d\twork
        """)

        XCTAssertEqual(listing.path, "/root")
        XCTAssertEqual(listing.entries.map(\.name), ["work"])
    }

    func test_listing_without_the_marker_is_rejected() {
        XCTAssertThrowsError(try RemoteDirectoryLister.parseListing("/home/deploy\nd\tapps")) { error in
            XCTAssertEqual(error as? RemoteDirectoryError, .malformedOutput)
        }
    }

    func test_listing_sorts_case_insensitively() throws {
        let listing = try RemoteDirectoryLister.parseListing("""
        \(RemoteDirectoryLister.marker)
        /srv
        d\tZebra
        d\tapple
        d\tBanana
        """)

        XCTAssertEqual(listing.entries.map(\.name), ["apple", "Banana", "Zebra"])
    }

    func test_listing_keeps_names_containing_tabs_intact() throws {
        let listing = try RemoteDirectoryLister.parseListing("""
        \(RemoteDirectoryLister.marker)
        /srv
        d\tmy\tfolder
        """)

        XCTAssertEqual(listing.entries.map(\.name), ["my\tfolder"])
    }

    func test_an_entry_knows_it_is_hidden() {
        XCTAssertTrue(RemoteDirectoryEntry(name: ".config", isGitRepository: false).isHidden)
        XCTAssertFalse(RemoteDirectoryEntry(name: "config", isGitRepository: false).isHidden)
    }

    // MARK: - Asking the question

    func test_listing_starts_at_the_remote_home_when_no_path_is_given() {
        let script = RemoteDirectoryLister.listScript(path: nil)

        XCTAssertTrue(script.contains("cd -- \"$HOME\""), script)
    }

    /// `~` means nothing to us — it has to reach the remote shell unquoted so
    /// *it* expands the tilde into *its* home.
    func test_a_leading_tilde_is_expanded_by_the_remote_shell() {
        XCTAssertEqual(RemoteDirectoryLister.remoteExpression(for: "~"), "\"$HOME\"")
        XCTAssertEqual(RemoteDirectoryLister.remoteExpression(for: "~/apps"), "\"$HOME\"/'apps'")
    }

    func test_paths_are_quoted_so_the_remote_shell_cannot_read_them() {
        XCTAssertEqual(RemoteDirectoryLister.remoteExpression(for: "/srv/my app"), "'/srv/my app'")
        XCTAssertEqual(
            RemoteDirectoryLister.remoteExpression(for: "/srv/$(rm -rf ~)"),
            "'/srv/$(rm -rf ~)'"
        )
        XCTAssertEqual(RemoteDirectoryLister.remoteExpression(for: "/srv/it's"), "'/srv/it'\\''s'")
    }

    func test_arguments_refuse_to_prompt_and_carry_the_user_and_port() {
        let info = SSHConnectionInfo(host: "example.com", user: "deploy", port: 2222)
        let args = RemoteDirectoryLister.arguments(for: info, script: "pwd")

        XCTAssertTrue(args.contains("BatchMode=yes"), "the picker must never block on a password prompt")
        XCTAssertEqual(args.firstIndex(of: "-p").map { args[$0 + 1] }, "2222")
        XCTAssertTrue(args.contains("deploy@example.com"), args.description)
    }

    func test_arguments_omit_the_port_and_user_when_unset() {
        let args = RemoteDirectoryLister.arguments(for: SSHConnectionInfo(host: "myhost"), script: "pwd")

        XCTAssertFalse(args.contains("-p"))
        XCTAssertTrue(args.contains("myhost"))
    }

    /// ssh hands the trailing words to the remote *login* shell, which parses
    /// them again. Unquoted, our script's `;` and `$e` are eaten there.
    func test_the_script_survives_the_remote_login_shell_as_one_word() {
        let args = RemoteDirectoryLister.arguments(for: SSHConnectionInfo(host: "myhost"), script: "echo 'hi'")

        XCTAssertEqual(args.suffix(3), ["/bin/sh", "-c", "'echo '\\''hi'\\'''"])
    }

    // MARK: - Believing the failure

    func test_ssh_failing_to_connect_is_a_connection_failure() {
        let error = RemoteDirectoryLister.failure(exitCode: 255, stderr: "Permission denied (publickey).\n")

        XCTAssertEqual(error, .connectionFailed("Permission denied (publickey)."))
    }

    func test_a_silent_connection_failure_still_says_something() {
        guard case .connectionFailed(let message) = RemoteDirectoryLister.failure(exitCode: 255, stderr: "  \n") else {
            return XCTFail("expected a connection failure")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func test_a_directory_that_will_not_open_is_reported_as_such() {
        XCTAssertEqual(
            RemoteDirectoryLister.failure(exitCode: 3, stderr: ""),
            .directoryUnavailable
        )
    }

    func test_a_refused_mkdir_carries_the_remote_message() {
        XCTAssertEqual(
            RemoteDirectoryLister.failure(exitCode: 4, stderr: "mkdir: apps: Permission denied\n"),
            .createFailed("mkdir: apps: Permission denied")
        )
    }

    func test_an_unexpected_exit_code_keeps_its_number() {
        XCTAssertEqual(
            RemoteDirectoryLister.failure(exitCode: 127, stderr: "sh: not found"),
            .commandFailed(code: 127, message: "sh: not found")
        )
    }

    // MARK: - Making a folder

    func test_creating_a_folder_echoes_where_it_landed() throws {
        let script = RemoteDirectoryLister.createScript(in: "/srv", named: "new app")

        XCTAssertTrue(script.contains("cd -- '/srv'"), script)
        XCTAssertTrue(script.contains("mkdir -- 'new app'"), script)
        XCTAssertTrue(script.contains("cd -- 'new app'"), script)
        XCTAssertTrue(script.contains("pwd"), script)
    }

    func test_a_folder_name_may_not_be_a_path() {
        XCTAssertFalse(RemoteDirectoryLister.isValidFolderName("apps/nested"))
        XCTAssertFalse(RemoteDirectoryLister.isValidFolderName(".."))
        XCTAssertFalse(RemoteDirectoryLister.isValidFolderName("."))
        XCTAssertFalse(RemoteDirectoryLister.isValidFolderName("   "))
        XCTAssertFalse(RemoteDirectoryLister.isValidFolderName(""))
        XCTAssertTrue(RemoteDirectoryLister.isValidFolderName("apps"))
        XCTAssertTrue(RemoteDirectoryLister.isValidFolderName(".hidden"))
    }

    // MARK: - Walking up

    func test_the_parent_of_a_nested_path_is_its_directory() {
        XCTAssertEqual(RemoteDirectoryLister.parentPath(of: "/srv/apps/web"), "/srv/apps")
        XCTAssertEqual(RemoteDirectoryLister.parentPath(of: "/srv"), "/")
    }

    func test_the_root_has_no_parent() {
        XCTAssertNil(RemoteDirectoryLister.parentPath(of: "/"))
    }
}
