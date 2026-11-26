import Foundation
import XCTest
@testable import NiceVideos

final class AfterglowPresetTests: XCTestCase {
    func testNewHeadsetPresetAndEditedPresetDoNotAlterMoviePreferences() throws {
        let suite = "AfterglowPresetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preset = AfterglowPreset.load(defaults: defaults)
        XCTAssertEqual(preset.mode, .immersive(.vr360, .sideBySide, headset: true))
        preset.eyes = .topBottom
        preset.fieldOfView = 95
        preset.headset = false
        AfterglowPreset.save(preset, defaults: defaults)
        XCTAssertEqual(AfterglowPreset.load(defaults: defaults), preset)
        XCTAssertEqual(VRMoviePreferences(key: "film", defaults: defaults).mode,
                       .immersive(.vr180, .sideBySide, headset: false))
    }
}
