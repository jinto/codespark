import XCTest
@testable import CodeSpark

/// The standard macOS About panel renders its version and copyright lines
/// straight from Info.plist. Missing keys silently produce a blank panel.
final class AppBundleMetadataTests: XCTestCase {

    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    func test_bundle_exposes_marketing_version() {
        let version = info["CFBundleShortVersionString"] as? String
        XCTAssertNotNil(version, "About panel shows no version without CFBundleShortVersionString")
        XCTAssertFalse(version?.isEmpty ?? true)
    }

    func test_bundle_exposes_build_number() {
        let build = info["CFBundleVersion"] as? String
        XCTAssertNotNil(build, "About panel shows no build number without CFBundleVersion")
        XCTAssertFalse(build?.isEmpty ?? true)
    }

    func test_bundle_exposes_copyright() {
        let copyright = info["NSHumanReadableCopyright"] as? String
        XCTAssertNotNil(copyright, "About panel shows no copyright without NSHumanReadableCopyright")
        XCTAssertFalse(copyright?.isEmpty ?? true)
    }

    // MARK: - Ghostty resources the build phase must ship

    /// `Bundle.main` here is the app under test — the test host is CodeSpark.app
    /// (`TEST_HOST` in project.pbxproj), so these assert the built application
    /// bundle, not a source tree.
    private var resources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent")
    }

    /// libghostty forces `TERM=xterm-ghostty` and computes
    /// `TERMINFO = dirname(GHOSTTY_RESOURCES_DIR)/terminfo` — i.e.
    /// `Contents/Resources/terminfo` — without checking the directory exists
    /// (`vendor/ghostty/src/termio/Exec.zig`). If the build phase doesn't ship
    /// the database, every shell gets a `TERM` it cannot resolve: backspace and
    /// line editing misrender on any machine without a fallback terminfo DB
    /// (`~/.terminfo` or system). The macOS entry Ghostty looks up as its
    /// sentinel is exactly `terminfo/78/xterm-ghostty` — `78` is hex for `x`,
    /// hard-coded at `vendor/ghostty/src/os/resourcesdir.zig:63`. A gap of one
    /// directory reproduces the whole bug, and it only shows when a real shell
    /// resolves `TERM`, so the existence check guards the source.
    func test_bundle_ships_the_ghostty_terminfo_entry() throws {
        let entry = resources.appendingPathComponent("terminfo/78/xterm-ghostty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path),
                      "no terminfo/78/xterm-ghostty in the bundle — TERM=xterm-ghostty is unresolvable")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: entry.path),
                      "the terminfo entry is present but not readable — ncurses still can't load it")
    }

    /// terminfo goes in as a *sibling* of `ghostty/`, because Ghostty derives
    /// the terminfo path from `dirname(GHOSTTY_RESOURCES_DIR)` and points
    /// `GHOSTTY_RESOURCES_DIR` at `Resources/ghostty` (`GhosttyRuntime.swift`).
    /// One level off and the sentinel lookup misses.
    func test_terminfo_is_a_sibling_of_the_ghostty_dir() {
        let terminfo = resources.appendingPathComponent("terminfo")
        let ghostty = resources.appendingPathComponent("ghostty")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminfo.path, isDirectory: &isDir) && isDir.boolValue,
                      "Resources/terminfo must be a directory beside Resources/ghostty")
    }

    /// The other half of the resources the build phase copies — shell
    /// integration feeds OSC 7 cwd reporting and prompt marks. It shares the
    /// build phase with terminfo, so a phase that half-runs should fail the gate.
    func test_bundle_ships_shell_integration() {
        let shellIntegration = resources.appendingPathComponent("ghostty/shell-integration")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: shellIntegration.path, isDirectory: &isDir) && isDir.boolValue,
                      "no ghostty/shell-integration in the bundle — cwd tracking silently dies")
    }
}
