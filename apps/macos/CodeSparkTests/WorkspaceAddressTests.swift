import XCTest
@testable import CodeSpark

/// The rules that were four separate `fix:` commits before they were a type.
final class WorkspaceAddressTests: XCTestCase {

    // MARK: - One directory, one spelling

    func test_a_local_path_is_spelled_one_way() {
        XCTAssertEqual(WorkspaceAddress("/private/tmp/proj").storageKey, "/tmp/proj",
                       "git prints the resolved directory; a project keeps what it was added with")
        XCTAssertEqual(WorkspaceAddress("/tmp/proj"), WorkspaceAddress("/private/tmp/proj"))
    }

    /// Deliberately *not* resolved: a path from another machine run through this
    /// one's filesystem is the confusion the whole scheme exists to avoid.
    func test_a_remote_address_is_left_as_the_host_spelled_it() {
        let uri = "ssh://box/private/var/folders/xyz/repo"
        XCTAssertEqual(WorkspaceAddress(uri).storageKey, uri)
        XCTAssertNotEqual(WorkspaceAddress("ssh://box/tmp/x"),
                          WorkspaceAddress("ssh://box/private/tmp/x"))
    }

    func test_a_trailing_slash_does_not_mint_a_second_workspace() {
        XCTAssertEqual(WorkspaceAddress("ssh://box/srv/repo/"), WorkspaceAddress("ssh://box/srv/repo"))
        XCTAssertEqual(WorkspaceAddress("/tmp/proj/"), WorkspaceAddress("/tmp/proj"))
    }

    /// Whatever is written to the store or UserDefaults has to read back as the
    /// same address, or the next launch is standing somewhere else.
    func test_an_address_survives_the_round_trip_through_storage() {
        for raw in ["/tmp/proj", "/private/tmp/proj", "ssh://jay@box:2222/srv/repo", "ssh://box"] {
            let once = WorkspaceAddress(raw)
            XCTAssertEqual(WorkspaceAddress(once.storageKey), once, raw)
        }
    }

    // MARK: - What git and the file APIs may be handed

    func test_only_a_local_address_offers_a_path_to_git() {
        XCTAssertEqual(WorkspaceAddress("/tmp/proj").localPath, "/tmp/proj")
        XCTAssertNil(WorkspaceAddress("ssh://box/srv/repo").localPath,
                     "`git -C 'ssh://…'` dies with `cannot change to` — it must not be reachable")
        XCTAssertEqual(WorkspaceAddress("ssh://box/srv/repo").remote?.remotePath, "/srv/repo")
        XCTAssertNil(WorkspaceAddress("/tmp/proj").remote)
    }

    func test_the_display_spelling_knows_which_machine_it_names() {
        XCTAssertEqual(WorkspaceAddress("ssh://box/srv/repo").displayName, "/srv/repo",
                       "tilde abbreviation would eat the `//` and leave `ssh:/box/srv/repo`")
        XCTAssertEqual(
            WorkspaceAddress(NSHomeDirectory() + "/code").displayName, "~/code")
    }

    // MARK: - Containment

    func test_a_sibling_worktree_is_not_inside_its_neighbour() {
        let proj = WorkspaceAddress("/tmp/proj")
        XCTAssertTrue(proj.contains(WorkspaceAddress("/tmp/proj")))
        XCTAssertTrue(proj.contains(WorkspaceAddress("/tmp/proj/src")))
        XCTAssertFalse(proj.contains(WorkspaceAddress("/tmp/proj-feature")),
                       "the separator is part of the test, or every sibling looks like a child")
        XCTAssertTrue(proj.contains(WorkspaceAddress("/private/tmp/proj/src")),
                      "the same directory by another spelling is still inside")
    }

    func test_nothing_on_one_machine_is_inside_anything_on_another() {
        XCTAssertFalse(
            WorkspaceAddress("/srv/repo").contains(WorkspaceAddress("ssh://box/srv/repo")))
        XCTAssertFalse(
            WorkspaceAddress("ssh://box/srv/repo").contains(WorkspaceAddress("/srv/repo/src")))
        XCTAssertFalse(
            WorkspaceAddress("ssh://box/srv").contains(WorkspaceAddress("ssh://other/srv/repo")),
            "same directory, different host")
        XCTAssertTrue(
            WorkspaceAddress("ssh://box/srv").contains(WorkspaceAddress("ssh://box/srv/repo")))
    }

    // MARK: - Membership, which is what the containment is for

    /// A tab belongs to the worktree it was opened in and keeps belonging to it
    /// after a `cd`. Only rows written before the column existed fall back to
    /// their directory.
    func test_a_tab_belongs_where_it_was_opened_and_not_where_it_wandered() {
        let wandered = SessionViewData(id: "s", title: "t", targetLabel: "local",
                                       lastCwd: "/tmp/elsewhere", workspacePath: "/tmp/proj")
        XCTAssertTrue(wandered.belongs(to: "/tmp/proj"))
        XCTAssertFalse(wandered.belongs(to: "/tmp/elsewhere"))

        let legacy = SessionViewData(id: "s", title: "t", targetLabel: "local",
                                     lastCwd: "/tmp/proj/src", workspacePath: "")
        XCTAssertTrue(legacy.belongs(to: "/tmp/proj"), "a row from before the column has only its cwd")
        XCTAssertFalse(legacy.belongs(to: "/tmp/proj-feature"))
    }

    // MARK: - The gates

    /// The services that run git receive an address and never derive one. A raw
    /// string classified in there is how `git -C 'ssh://…'` happened, and no
    /// test that reads a value back from the model can see it coming.
    func test_the_git_services_never_classify_a_raw_string() throws {
        let banned = ["hasPrefix(\"ssh://\")", "SSHConnectionInfo(uri:"]
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CodeSpark/Services")
        let files = try FileManager.default.contentsOfDirectory(at: services,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Git") }
        XCTAssertFalse(files.isEmpty, "the gate found no git services — it has gone blind")

        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for pattern in banned where line.contains(pattern) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)  "
                        + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "A git service told local from remote by reading the text. Take a "
                        + "`WorkspaceAddress` and let it say:\n" + offenders.joined(separator: "\n"))
    }

    /// `abbreviatingWithTildeInPath` on a URI leaves `ssh:/box/srv/repo`. One
    /// file is allowed to call it, and that file knows what it is holding.
    func test_only_the_address_type_abbreviates_a_path() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CodeSpark")
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            scanned += 1
            guard file.lastPathComponent != "WorkspaceAddress.swift" else { continue }
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard line.contains("abbreviatingWithTildeInPath") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)  "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertGreaterThan(scanned, 1, "the gate found no sources — it has gone blind")
        XCTAssertTrue(offenders.isEmpty,
                      "Only `WorkspaceAddress.displayName` may abbreviate — it is the only thing "
                        + "that knows whether it holds a path or a URI:\n"
                        + offenders.joined(separator: "\n"))
    }
}
