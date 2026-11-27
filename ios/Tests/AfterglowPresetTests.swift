import Foundation
import XCTest
@testable import NiceVideos

final class AfterglowPresetTests: XCTestCase {
    func testLegacyMovieAndAfterglowSettingsKeepOnlyTheirOwnFieldOfView() throws {
        let suite = "AfterglowPresetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let obsolete: [String: Any] = ["projection": VRProjection.vr180.rawValue,
                                       "eyes": VREyeLayout.topBottom.rawValue, "headset": false, "fov": 95.0]
        defaults.set(obsolete, forKey: "vr.afterglow.profile")
        defaults.set(obsolete.merging(["fov": 61.0]) { _, new in new }, forKey: "vr.movie.film")
        var preset = AfterglowPreset.load(defaults: defaults)
        XCTAssertEqual(VRMoviePreferences.mode, .immersive(.vr360, .sideBySide, headset: true))
        XCTAssertEqual(preset.fieldOfView, 95)
        preset.fieldOfView = 85
        AfterglowPreset.save(preset, defaults: defaults)
        XCTAssertEqual(AfterglowPreset.load(defaults: defaults), preset)
        XCTAssertEqual(Set(preset.values.keys), ["fov"])
        XCTAssertEqual(VRMoviePreferences(key: "film", defaults: defaults).fieldOfView, 61)
    }
}
