import XCTest
@testable import CodeSpark

@MainActor
final class RemoteFolderPickerModelTests: XCTestCase {

    func test_it_opens_on_the_remote_home_directory() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": ["apps", "logs"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)

        await model.load()

        XCTAssertEqual(model.path, "/home/deploy")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.visibleEntries.map(\.name), ["apps", "logs"])
    }

    func test_it_opens_on_the_path_the_project_already_has() async {
        let source = FakeRemoteDirectorySource(tree: ["/srv/app": ["dist"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: "/srv/app")

        await model.load()

        XCTAssertEqual(model.path, "/srv/app")
    }

    func test_hidden_folders_stay_out_of_the_way_until_asked_for() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": [".config", "apps"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        XCTAssertEqual(model.visibleEntries.map(\.name), ["apps"])

        model.showsHiddenFolders = true

        XCTAssertEqual(model.visibleEntries.map(\.name), [".config", "apps"])
    }

    func test_opening_a_folder_descends_into_it() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["apps"], "/home/deploy/apps": ["web"]],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        await model.open("apps")

        XCTAssertEqual(model.path, "/home/deploy/apps")
        XCTAssertEqual(model.visibleEntries.map(\.name), ["web"])
    }

    func test_going_up_lands_in_the_parent() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["apps"], "/home": ["deploy"]],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        XCTAssertTrue(model.canGoUp)
        await model.goUp()

        XCTAssertEqual(model.path, "/home")
    }

    func test_the_root_has_nowhere_to_go_up_to() async {
        let source = FakeRemoteDirectorySource(tree: ["/": ["etc"]], home: "/")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        XCTAssertFalse(model.canGoUp)
    }

    // MARK: - What "Choose" means

    func test_choosing_nothing_in_particular_takes_the_folder_we_are_in() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": ["apps"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        XCTAssertEqual(model.chosenPath, "/home/deploy")
    }

    /// Picking a folder you can see beats having to walk into it first.
    func test_choosing_with_a_folder_selected_takes_that_folder() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": ["apps"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.selectedName = "apps"

        XCTAssertEqual(model.chosenPath, "/home/deploy/apps")
    }

    func test_a_selection_does_not_follow_us_into_the_next_folder() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["apps"], "/home/deploy/apps": ["web"]],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()
        model.selectedName = "apps"

        await model.open("apps")

        XCTAssertNil(model.selectedName)
        XCTAssertEqual(model.chosenPath, "/home/deploy/apps")
    }

    func test_hiding_the_hidden_folders_gives_up_a_hidden_choice() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": [".config", "apps"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()
        model.showsHiddenFolders = true
        model.selectedName = ".config"
        XCTAssertEqual(model.chosenPath, "/home/deploy/.config")

        model.showsHiddenFolders = false

        XCTAssertNil(model.selectedName, "Choose must not hand back a folder that left the screen")
        XCTAssertEqual(model.chosenPath, "/home/deploy")
    }

    func test_hiding_the_hidden_folders_keeps_a_visible_choice() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": [".config", "apps"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()
        model.showsHiddenFolders = true
        model.selectedName = "apps"

        model.showsHiddenFolders = false

        XCTAssertEqual(model.selectedName, "apps")
    }

    // MARK: - One folder at a time

    /// Every click starts its own task, so two listings can be in the air at
    /// once. The one that comes back late must not drag the user backwards.
    func test_a_late_listing_cannot_overwrite_a_newer_one() async {
        let source = FakeRemoteDirectorySource(
            tree: [
                "/home/deploy": ["slow", "fast"],
                "/home/deploy/slow": ["stale"],
                "/home/deploy/fast": ["fresh"],
            ],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        source.pause(at: "/home/deploy/slow")
        let late = Task { await model.open("slow") }
        await Task.yield()
        await model.open("fast")
        source.resume()
        await late.value

        XCTAssertEqual(model.path, "/home/deploy/fast")
        XCTAssertEqual(model.visibleEntries.map(\.name), ["fresh"])
    }

    func test_there_is_nothing_to_choose_while_a_folder_is_opening() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["apps"], "/home/deploy/apps": []],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        source.pause(at: "/home/deploy/apps")
        let opening = Task { await model.open("apps") }
        await Task.yield()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.canChoose)

        source.resume()
        await opening.value

        XCTAssertTrue(model.canChoose)
    }

    // MARK: - When the host says no

    func test_a_connection_failure_is_shown_not_swallowed() async {
        let source = FakeRemoteDirectorySource(tree: [:], home: "/home/deploy")
        source.failure = .connectionFailed("Permission denied (publickey).")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)

        await model.load()

        XCTAssertEqual(model.phase, .failed("Permission denied (publickey)."))
        XCTAssertFalse(model.canChoose, "there is no folder to choose yet")
    }

    /// A folder we cannot enter must not strand the picker — it stays put.
    func test_a_folder_that_will_not_open_leaves_us_where_we_were() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": ["apps", "secret"]], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        await model.open("secret")  // not in the tree — the host refuses

        XCTAssertEqual(model.path, "/home/deploy")
        XCTAssertEqual(model.visibleEntries.map(\.name), ["apps", "secret"])
        XCTAssertEqual(model.phase, .failed("Can't open that folder."))
    }

    // MARK: - Making a folder

    func test_creating_a_folder_moves_into_it() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": []], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.newFolderName = "app"
        await model.createFolder()

        XCTAssertEqual(model.path, "/home/deploy/app")
        XCTAssertEqual(model.newFolderName, "", "the field is spent once the folder exists")
    }

    /// Making a folder is a round trip like any other, so it has to lose the
    /// same way: if the user walked off while mkdir was in the air, the folder
    /// gets made but nobody gets dragged into it.
    func test_a_late_folder_creation_does_not_drag_us_out_of_where_we_are() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["elsewhere"], "/home/deploy/elsewhere": ["there"]],
            home: "/home/deploy"
        )
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.newFolderName = "app"
        source.pauseCreation(in: "/home/deploy")
        let creating = Task { await model.createFolder() }
        await Task.yield()
        await model.open("elsewhere")
        source.resumeCreation()
        await creating.value

        XCTAssertEqual(model.path, "/home/deploy/elsewhere")
        XCTAssertEqual(model.visibleEntries.map(\.name), ["there"])
    }

    func test_a_late_creation_error_does_not_stain_the_folder_we_moved_to() async {
        let source = FakeRemoteDirectorySource(
            tree: ["/home/deploy": ["elsewhere"], "/home/deploy/elsewhere": []],
            home: "/home/deploy"
        )
        source.creationFailure = .createFailed("mkdir: app: Permission denied")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.newFolderName = "app"
        source.pauseCreation(in: "/home/deploy")
        let creating = Task { await model.createFolder() }
        await Task.yield()
        await model.open("elsewhere")
        source.resumeCreation()
        await creating.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.phase, .loaded)
    }

    func test_a_folder_cannot_be_created_twice_while_the_first_is_in_flight() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": []], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.newFolderName = "app"
        source.pauseCreation(in: "/home/deploy")
        let creating = Task { await model.createFolder() }
        await Task.yield()

        XCTAssertFalse(model.canCreateFolder, "Create must go quiet while it is already running")

        source.resumeCreation()
        await creating.value

        XCTAssertEqual(source.createdNames, ["app"])
    }

    func test_a_folder_name_that_is_a_path_never_reaches_the_host() async {
        let source = FakeRemoteDirectorySource(tree: ["/home/deploy": []], home: "/home/deploy")
        let model = RemoteFolderPickerModel(source: source, startingAt: nil)
        await model.load()

        model.newFolderName = "../escape"

        XCTAssertFalse(model.canCreateFolder)
        await model.createFolder()

        XCTAssertEqual(source.createdNames, [])
        XCTAssertEqual(model.path, "/home/deploy")
    }
}

/// A remote host that only exists in this test file. Its gates let a test hold
/// one round trip open and decide which answer comes back last.
private final class FakeRemoteDirectorySource: RemoteDirectorySource, @unchecked Sendable {
    private let lock = NSLock()
    private let listings = Gate()
    private let creations = Gate()
    private var tree: [String: [String]]
    private let home: String
    private var storedFailure: RemoteDirectoryError?
    private var storedCreationFailure: RemoteDirectoryError?
    private var names: [String] = []

    init(tree: [String: [String]], home: String) {
        self.tree = tree
        self.home = home
    }

    var failure: RemoteDirectoryError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    /// Fails only `createDirectory`, so a test can watch a doomed mkdir race a
    /// perfectly good listing.
    var creationFailure: RemoteDirectoryError? {
        get { lock.withLock { storedCreationFailure } }
        set { lock.withLock { storedCreationFailure = newValue } }
    }

    var createdNames: [String] { lock.withLock { names } }

    func pause(at path: String) { listings.pause(path) }
    func resume() { listings.open() }
    func pauseCreation(in parent: String) { creations.pause(parent) }
    func resumeCreation() { creations.open() }

    func listDirectory(at path: String?) async throws -> RemoteDirectoryListing {
        let resolved = path ?? home
        await listings.wait(resolved)
        return try lock.withLock {
            if let storedFailure { throw storedFailure }
            guard let children = tree[resolved] else { throw RemoteDirectoryError.directoryUnavailable }
            return RemoteDirectoryListing(
                path: resolved,
                entries: children.map { RemoteDirectoryEntry(name: $0, isGitRepository: false) }
            )
        }
    }

    func createDirectory(in parent: String, named name: String) async throws -> String {
        await creations.wait(parent)
        return try lock.withLock {
            if let failure = storedCreationFailure ?? storedFailure { throw failure }
            names.append(name)
            let created = parent == "/" ? "/" + name : parent + "/" + name
            tree[parent, default: []].append(name)
            tree[created] = []
            return created
        }
    }

    /// Holds one caller at a named key until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var pausedKey: String?
        private var waiter: CheckedContinuation<Void, Never>?

        func pause(_ key: String) { lock.withLock { pausedKey = key } }

        func open() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                pausedKey = nil
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func wait(_ key: String) async {
            await withCheckedContinuation { continuation in
                let held: Bool = lock.withLock {
                    guard pausedKey == key else { return false }
                    waiter = continuation
                    return true
                }
                // `open()` may already have run — then nothing holds this back.
                if !held { continuation.resume() }
            }
        }
    }
}
