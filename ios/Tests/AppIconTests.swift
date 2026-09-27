import XCTest
@testable import NiceVideos

final class AppIconTests: XCTestCase {
    func testPrimaryIconIsCompiledIntoHostApplication() throws {
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String])
        XCTAssertFalse(files.isEmpty, "The host app must contain compiled home-screen icons.")
    }
}
