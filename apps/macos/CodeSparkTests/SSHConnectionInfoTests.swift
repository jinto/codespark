import XCTest
@testable import CodeSpark

final class SSHConnectionInfoTests: XCTestCase {

    func test_parse_host_only() {
        let info = SSHConnectionInfo(uri: "ssh://myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertNil(info.port)
        XCTAssertNil(info.remotePath)
        XCTAssertEqual(info.sshCommand(), "ssh -- 'myhost'")
        XCTAssertEqual(info.displayLabel, "myhost")
    }

    func test_parse_user_and_host() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.sshCommand(), "ssh -- 'jinto@myhost'")
        XCTAssertEqual(info.displayLabel, "jinto@myhost")
    }

    func test_parse_host_and_path() {
        let info = SSHConnectionInfo(uri: "ssh://myhost/home/user/project")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertNil(info.user)
        XCTAssertEqual(info.remotePath, "/home/user/project")
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: nil)), "cd '/home/user/project' || exit")
    }

    func test_parse_full_uri() {
        let info = SSHConnectionInfo(uri: "ssh://jinto@myhost:2222/srv/app")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.user, "jinto")
        XCTAssertEqual(info.port, 2222)
        XCTAssertEqual(info.remotePath, "/srv/app")
        XCTAssertTrue(info.sshCommand().hasPrefix("ssh -p 2222 -- 'jinto@myhost' -t "), info.sshCommand())
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: nil)), "cd '/srv/app' || exit")
    }

    func test_parse_host_and_port() {
        let info = SSHConnectionInfo(uri: "ssh://myhost:8022")!
        XCTAssertEqual(info.host, "myhost")
        XCTAssertEqual(info.port, 8022)
        XCTAssertNil(info.user)
        XCTAssertEqual(info.sshCommand(), "ssh -p 8022 -- 'myhost'")
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
        XCTAssertEqual(info.sshCommand(), "ssh -- 'myhost'")
    }

    // MARK: - A host is not an option
    //
    // ssh reads any argv element beginning with `-` as an option, wherever it
    // sits. The host is free text from the New SSH Project sheet, it is stored,
    // and the 10-second worktree poll re-reads it — so `-oProxyCommand=…` would
    // run a local command over and over, unattended.
    //
    // The host was already shell-quoted, with a comment explaining why. Quoting
    // defends the shell; it does nothing about the argv position. Two layers
    // here: refuse it at the parser so it can never be stored, and separate the
    // destination with `--` so a value that reaches ssh anyway is still data.

    func test_a_host_that_would_be_read_as_an_option_is_refused() {
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://-oProxyCommand=id/srv/repo"))
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://-oProxyCommand=id"))
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://user@-oProxyCommand=id/srv"))
    }

    func test_a_user_that_would_be_read_as_an_option_is_refused() {
        XCTAssertNil(SSHConnectionInfo(uri: "ssh://-l@box/srv"))
    }

    /// A hyphen inside the name is fine — only a leading one is an option.
    func test_an_ordinary_hyphenated_host_still_parses() {
        let info = SSHConnectionInfo(uri: "ssh://build-box-01/srv")
        XCTAssertEqual(info?.host, "build-box-01")
    }

    func test_every_ssh_invocation_separates_its_destination() throws {
        let info = try XCTUnwrap(SSHConnectionInfo(uri: "ssh://jinto@box:2222/srv/repo"))

        for (label, argv) in [
            ("worktree scan", GitWorktreeService.remoteSSHArguments(info, remoteCommand: "true")),
            ("folder picker", RemoteDirectoryLister.arguments(for: info, script: "true")),
            ("image paste", ClipboardImageHandler.scpArguments(localPath: "/tmp/a.png", sshInfo: info).args),
        ] {
            let separator = try XCTUnwrap(
                argv.firstIndex(of: "--"),
                "\(label): no `--` before the destination — a host beginning with a dash is an option")
            XCTAssertTrue(
                argv[(separator + 1)...].contains { $0.contains("box") },
                "\(label): `--` does not precede the destination")
        }

        XCTAssertTrue(
            info.sshCommand().contains(" -- "),
            "sshCommand: the tab's own ssh line has no `--`")
    }

    // MARK: - A home-relative path

    /// The URI's path component has to start with a slash, so a `~/…` path was
    /// stored as `/~/…` and came back that way — `cd '/~/projects/x'`, which no
    /// machine has.
    func test_a_tilde_path_survives_the_uri_round_trip() {
        let info = SSHConnectionInfo(host: "box", remotePath: "~/projects/xxx")
        let parsed = SSHConnectionInfo(uri: info.uri)
        XCTAssertEqual(parsed?.remotePath, "~/projects/xxx")
    }

    /// Even spelled correctly, `cd '~/projects/xxx'` fails: quoting is what stops
    /// the remote shell expanding the tilde, and the quoting is there because the
    /// rest of the path must survive as one word.
    func test_a_tilde_is_left_for_the_remote_shell_to_expand() throws {
        let info = SSHConnectionInfo(host: "box", remotePath: "~/projects/xxx")
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: nil)),
                       "cd \"$HOME\"/'projects/xxx' || exit")
    }

    func test_an_absolute_path_is_untouched() throws {
        let info = SSHConnectionInfo(host: "box", remotePath: "/srv/app")
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: nil)), "cd '/srv/app' || exit")
    }

    // MARK: - What ssh actually receives
    //
    // Ghostty runs a surface command through `/bin/sh -c` (embedded.zig sets
    // `config.command = .{ .shell = cmd }`), so asserting the command *string*
    // proves nothing: the local shell parses it first. These tests run the
    // string through a real `/bin/sh` with a stub `ssh` and check the argv.

    func test_the_remote_command_reaches_ssh_as_a_single_argument() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost/srv/app")!
        let argv = try argumentsSSHReceives(from: info.sshCommand())
        XCTAssertEqual(argv.count, 4, "the remote command must reach ssh whole: \(argv)")
        XCTAssertEqual(argv.first, "--", "the destination must be separated from the options")
        XCTAssertEqual(argv.dropFirst().first, "myhost")
        XCTAssertEqual(argv.dropFirst(2).first, "-t")
        let remote = try XCTUnwrap(argv.last)
        XCTAssertTrue(remote.hasPrefix("/bin/sh -c "), remote)
    }

    func test_a_replay_rides_along_inside_the_remote_command() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost/srv/app")!
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: "printf '%b' 'screen'")),
                       "printf '%b' 'screen'")
        XCTAssertEqual(try argumentsSSHReceives(from: info.sshCommand(replaying: "printf '%b' 'screen'")).count, 4)
    }

    func test_a_replay_opens_a_shell_even_without_a_remote_path() throws {
        let info = SSHConnectionInfo(uri: "ssh://myhost")!
        let script = try XCTUnwrap(info.remoteCommand(replaying: "printf '%b' 'screen'"))
        XCTAssertEqual(firstLine(script), "printf '%b' 'screen'")
        XCTAssertTrue(script.contains("exec \"$__cs_s\""), script)
    }

    /// The host comes from a free-text field in the New SSH Project sheet, and
    /// the whole command is parsed by the local `/bin/sh` before ssh ever sees
    /// it. Unquoted, everything after a `;` runs on this machine.
    func test_a_host_with_a_shell_metacharacter_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "box; touch /tmp/codespark-should-not-exist",
                                     remotePath: "/srv/app")
        let argv = try argumentsSSHReceives(from: info.sshCommand())
        XCTAssertEqual(argv.dropFirst().first, "box; touch /tmp/codespark-should-not-exist")
        XCTAssertEqual(argv.count, 4, "\(argv)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/codespark-should-not-exist"),
                       "the local shell ran what was typed into the host field")
    }

    func test_a_user_with_a_shell_metacharacter_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "box", user: "jay$(id -u)", remotePath: "/srv/app")
        let argv = try argumentsSSHReceives(from: info.sshCommand())
        XCTAssertEqual(argv.dropFirst().first, "jay$(id -u)@box")
        XCTAssertEqual(argv.count, 4, "\(argv)")
    }

    func test_a_remote_path_with_a_quote_stays_one_argument() throws {
        let info = SSHConnectionInfo(host: "myhost", remotePath: "/srv/it's here")
        XCTAssertEqual(firstLine(info.remoteCommand(replaying: nil)),
                       "cd '/srv/it'\\''s here' || exit")
    }

    /// The `cd` the remote shell runs first, before the reporter's launcher.
    private func firstLine(_ script: String?) -> String {
        (script ?? "").components(separatedBy: "\n").first ?? ""
    }

    /// Runs `command` the way Ghostty does and returns the argv a stub `ssh`
    /// sees. `SHELL` is set to a marker so local expansion is detectable.
    private func argumentsSSHReceives(from command: String) throws -> [String] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-ssh-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorded = directory.appendingPathComponent("argv")
        let stub = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\0' "$argument" >> '\(recorded.path)'; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": directory.path, "SHELL": "/local/shell"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        // NUL-separated, not newline: the remote command is several lines
        // long, and splitting on newlines would report one argument as many —
        // which is the very thing these tests exist to catch.
        let text = (try? String(contentsOf: recorded, encoding: .utf8)) ?? ""
        return text.split(separator: "\0").map(String.init)
    }

    // MARK: - Workspace addressing

    // A worktree on the other machine has to be addressable in the same string
    // space as the project itself — `workspacePath` is one column, and it is
    // what grouping, selection, restore, and removal all compare.

    func test_workspace_address_carries_the_connection_authority() {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222, remotePath: "/srv/repo")
        XCTAssertEqual(
            info.address(forRemotePath: "/srv/worktrees/repo-feat-ab12").storageKey,
            "ssh://jay@box:2222/srv/worktrees/repo-feat-ab12"
        )
    }

    func test_a_workspace_address_round_trips_to_the_remote_path() {
        let info = SSHConnectionInfo(host: "box", remotePath: "/srv/repo")
        let address = info.address(forRemotePath: "/srv/wt/a b")
        XCTAssertEqual(address.remote?.remotePath, "/srv/wt/a b")
    }

    func test_root_survives_canonicalization() {
        XCTAssertEqual(SSHConnectionInfo.canonicalRemotePath("/"), "/")
    }

    func test_shell_quoting_survives_an_apostrophe() {
        XCTAssertEqual(RemoteShell.quoted("/srv/it's here"), "'/srv/it'\\''s here'")
    }

    // MARK: - A real shell on the other side
    //
    // The reporter lives or dies on shell startup order — which file is read
    // when, and what `$ZDOTDIR` points at while it happens. None of that shows
    // up in the command string, so these tests take what the remote side would
    // actually be handed and run it through a real shell here.

    /// The directories a run reported, read out of the OSC 7 sequences the way
    /// Ghostty reads them — including the percent-decode, which is the whole
    /// point: Ghostty runs the payload through `std.Uri` and
    /// `toRawMaybeAlloc` (`termio/stream_handler.zig`), so what it concludes is
    /// the *decoded* path, not the bytes we printed.
    private func reportedDirectories(in output: String) -> [String] {
        output.components(separatedBy: "\u{1B}]7;file://localhost")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "\u{07}").first }
            .map { decodedAsGhosttyWould($0) }
    }

    /// `#` opens a fragment and `?` a query, so both truncate the path; `%NN`
    /// decodes. Mirrors what `std.Uri` does to the payload.
    private func decodedAsGhosttyWould(_ payload: String) -> String {
        let path = payload.prefix { $0 != "#" && $0 != "?" }
        return String(path).removingPercentEncoding ?? String(path)
    }

    private func runRemoteScript(
        shell: String,
        remotePath: String? = nil,
        planting dotfiles: [String: String] = [:],
        path: String = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        typing input: String
    ) throws -> String {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for (name, body) in dotfiles {
            let file = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
        }

        let info = SSHConnectionInfo(host: "box", remotePath: remotePath ?? home.path)
        let script = try XCTUnwrap(info.remoteCommand(replaying: nil))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // A deliberately bare environment: HOME points into the temporary
        // directory so the reporter's cache lands there and the developer's own
        // dotfiles never take part.
        process.environment = [
            "PATH": path,
            "HOME": home.path,
            "SHELL": shell,
            "TERM": "dumb",
        ]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func test_a_real_zsh_reports_the_directory_it_moved_to() throws {
        let output = try runRemoteScript(shell: "/bin/zsh", typing: "cd /tmp\nexit\n")
        XCTAssertTrue(reportedDirectories(in: output).contains("/tmp"),
                      "zsh never reported a directory: \(output.debugDescription)")
    }

    func test_a_real_bash_reports_the_directory_it_moved_to() throws {
        let output = try runRemoteScript(shell: "/bin/bash", typing: "cd /tmp\nexit\n")
        XCTAssertTrue(reportedDirectories(in: output).contains("/tmp"),
                      "bash never reported a directory: \(output.debugDescription)")
    }

    static let installedFish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func test_a_real_fish_reports_the_directory_it_moved_to() throws {
        let shell = try XCTUnwrap(Self.installedFish, "fish is not installed here")
        let output = try runRemoteScript(shell: shell, typing: "cd /tmp\nexit\n")
        XCTAssertTrue(reportedDirectories(in: output).contains("/tmp"),
                      "fish never reported a directory: \(output.debugDescription)")
    }

    /// The payload is a URI, and `$PWD` was printed into it raw. A directory
    /// named `a%20b` was therefore reported as `a b`, and one containing `#` or
    /// `?` was reported truncated at that character — the tab's cwd silently
    /// became some other directory, and the next restore opened that one.
    ///
    /// Ghostty's own shell integration encodes; this reimplementation of it
    /// did not.
    func test_a_directory_whose_name_is_a_uri_delimiter_survives_the_round_trip() throws {
        for shell in ["/bin/zsh", "/bin/bash"] + (Self.installedFish.map { [$0] } ?? []) {
            let awkward = try makeDirectory(named: "a%20b #1?x")
            defer { try? FileManager.default.removeItem(atPath: awkward) }

            let output = try runRemoteScript(
                shell: shell,
                typing: "cd '\(awkward)'\nexit\n"
            )

            XCTAssertTrue(
                reportedDirectories(in: output).contains(awkward),
                "\(shell) reported \(reportedDirectories(in: output)) for \(awkward)")
        }
    }

    private func makeDirectory(named name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-odd-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The shell reports `$PWD`, which is the path after symlink resolution —
        // /var vs /private/var on this machine.
        return (url.path as NSString).resolvingSymlinksInPath
    }

    /// Ghostty throws away OSC 7 whose host it cannot recognise as local, and a
    /// remote shell's own `$HOST` is precisely that. Claiming `localhost` is the
    /// only spelling that survives the crossing.
    func test_the_report_claims_to_come_from_localhost() throws {
        let script = try XCTUnwrap(
            SSHConnectionInfo(host: "box", remotePath: "/srv").remoteCommand(replaying: nil)
        )
        XCTAssertTrue(script.contains("file://localhost"), script)
        XCTAssertFalse(script.contains("$HOST"),
                       "a remote $HOST is exactly what Ghostty drops")
    }

    /// `/etc/zshrc` is read between our `.zshenv` and our `.zshrc`, and it sets
    /// HISTFILE from whatever ZDOTDIR happens to be at that moment. Left alone,
    /// every remote zsh quietly starts writing its history into our cache.
    func test_zsh_keeps_its_history_where_it_always_was() throws {
        let output = try runRemoteScript(shell: "/bin/zsh", typing: "echo \"HIST=$HISTFILE\"\nexit\n")
        XCTAssertTrue(output.contains("HIST="), output.debugDescription)
        XCTAssertFalse(output.contains("codespark/shell"),
                       "the remote shell's history moved into our cache: \(output)")
    }

    /// The shell is handed back its own dotfile directory before the user's rc
    /// runs — anything derived from `$ZDOTDIR` in there would otherwise point
    /// into our cache.
    func test_zsh_gets_its_own_dotfile_directory_back() throws {
        let output = try runRemoteScript(shell: "/bin/zsh", typing: "echo \"Z=[$ZDOTDIR]\"\nexit\n")
        XCTAssertFalse(output.contains("codespark/shell"),
                       "ZDOTDIR still points at our cache: \(output)")
    }

    // MARK: - The remote shell is a login shell
    //
    // On macOS the base PATH is assembled by `/usr/libexec/path_helper`, and the
    // only thing that calls it is `/etc/zprofile` — a login file. A remote shell
    // that was merely interactive got none of it: `.zshrc` still aliased `vi` to
    // `nvim` while `nvim` itself was nowhere on `$PATH`, because
    // `/etc/paths.d/homebrew` had never been read. Everything a person puts in
    // `~/.zprofile` or `~/.bash_profile` — which is where Homebrew's own
    // instructions put it — was missing for the same reason.
    //
    // Ghostty runs local shells through `login(1)` for exactly this reason
    // (`termio/Exec.zig`: "macOS users expect all their terminals to be login
    // shells"), so a remote tab that is not one makes two halves of the same app
    // behave like two different machines.

    func test_a_real_zsh_runs_the_users_login_profile() throws {
        let output = try runRemoteScript(
            shell: "/bin/zsh",
            planting: [".zprofile": "echo CS_PROFILE_RAN"],
            typing: "exit\n"
        )
        XCTAssertTrue(output.contains("CS_PROFILE_RAN"),
                      "~/.zprofile never ran: \(output.debugDescription)")
    }

    /// `$ZDOTDIR` points into our cache while zsh looks for `.zprofile`, so the
    /// shim has to hand the directory back and take it again — the same dance
    /// `.zshenv` does, one file later.
    func test_a_real_zsh_still_runs_the_users_rc() throws {
        let output = try runRemoteScript(
            shell: "/bin/zsh",
            planting: [".zprofile": "echo CS_PROFILE_RAN", ".zshrc": "echo CS_RC_RAN"],
            typing: "exit\n"
        )
        XCTAssertTrue(output.contains("CS_RC_RAN"),
                      "the profile shim lost the rc that follows it: \(output.debugDescription)")
    }

    func test_a_real_zsh_runs_the_users_login_file() throws {
        let output = try runRemoteScript(
            shell: "/bin/zsh",
            planting: [".zlogin": "echo CS_LOGIN_RAN"],
            typing: "exit\n"
        )
        XCTAssertTrue(output.contains("CS_LOGIN_RAN"),
                      "~/.zlogin never ran: \(output.debugDescription)")
    }

    /// The complaint itself, measured rather than inferred: `path_helper` reads
    /// `/etc/paths` and `/etc/paths.d/*` and is called from `/etc/zprofile`
    /// alone, so a shell that is not a login shell starts with whatever `sshd`
    /// handed it. `/usr/local/bin` is in `/etc/paths` on every macOS and in no
    /// bare environment, which makes it the marker.
    func test_a_real_zsh_gets_the_path_the_system_builds_for_it() throws {
        let output = try runRemoteScript(
            shell: "/bin/zsh",
            path: "/usr/bin:/bin",
            typing: "echo \"P=$PATH\"\nexit\n"
        )
        XCTAssertTrue(output.contains("/usr/local/bin"),
                      "path_helper never ran, so /etc/paths.d was never read: \(output)")
    }

    func test_a_real_bash_runs_the_users_login_profile() throws {
        let output = try runRemoteScript(
            shell: "/bin/bash",
            planting: [".bash_profile": "echo CS_PROFILE_RAN"],
            typing: "exit\n"
        )
        XCTAssertTrue(output.contains("CS_PROFILE_RAN"),
                      "~/.bash_profile never ran: \(output.debugDescription)")
    }

    func test_a_real_fish_runs_as_a_login_shell() throws {
        let shell = try XCTUnwrap(Self.installedFish, "fish is not installed here")
        let output = try runRemoteScript(
            shell: shell,
            planting: [".config/fish/config.fish": "if status is-login\necho CS_PROFILE_RAN\nend"],
            typing: "exit\n"
        )
        XCTAssertTrue(output.contains("CS_PROFILE_RAN"),
                      "fish did not start as a login shell: \(output.debugDescription)")
    }

    /// Anything we do not recognise has to end in a shell anyway. Before the
    /// reporter existed an ssh tab always got one, and failing to install a
    /// convenience must never cost the user their terminal.
    func test_an_unrecognised_shell_still_opens() throws {
        let output = try runRemoteScript(shell: "/bin/sh", typing: "echo OPENED\nexit\n")
        XCTAssertTrue(output.contains("OPENED"), output.debugDescription)
    }

    /// A worktree can be removed on the far side while a tab still points into
    /// it. Opening a shell in the wrong directory is worse than opening none —
    /// the tab would then report *that* directory as its own.
    func test_a_directory_that_is_gone_opens_no_shell() throws {
        let output = try runRemoteScript(
            shell: "/bin/zsh",
            remotePath: "/nonexistent-\(UUID().uuidString)",
            typing: "echo OPENED\nexit\n"
        )
        XCTAssertFalse(output.contains("OPENED"),
                       "a shell opened somewhere other than the tab's directory: \(output)")
    }

    // MARK: - What a sheet shows a person

    /// The New SSH Project and Change Remote Folder sheets print the command
    /// under the path field so the host, port, and folder can be checked at a
    /// glance. The reporter's launcher is identical for every project and says
    /// nothing about any of them — printed in full it buries the two lines the
    /// sheet exists for, and fills the window.
    func test_the_preview_is_one_readable_line() {
        let info = SSHConnectionInfo(host: "emac", remotePath: "/Users/jinto/projects/codespark")
        let preview = info.previewCommand
        XCTAssertFalse(preview.contains("\n"), "the preview flooded the sheet: \(preview)")
        XCTAssertFalse(preview.contains("CS_RC_DIR"), preview)
        XCTAssertTrue(preview.contains("emac"), preview)
        XCTAssertTrue(preview.contains("/Users/jinto/projects/codespark"), preview)
    }

    func test_the_preview_still_shows_the_port_and_user() {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222, remotePath: "/srv/app")
        XCTAssertTrue(info.previewCommand.contains("-p 2222"), info.previewCommand)
        XCTAssertTrue(info.previewCommand.contains("jay@box"), info.previewCommand)
    }

    /// A view that reaches for the real command gets the launcher with it. This
    /// is the shape of the mistake, not a detail of one sheet — the sheets that
    /// already made it looked fine until the command grew.
    func test_no_view_prints_the_raw_ssh_command() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // CodeSparkTests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("CodeSpark/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no view sources found at \(views.path)")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(".sshCommand("),
                           "\(file.lastPathComponent) prints the whole remote command — use previewCommand")
        }
    }
}
