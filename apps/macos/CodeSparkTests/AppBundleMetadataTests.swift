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
}
