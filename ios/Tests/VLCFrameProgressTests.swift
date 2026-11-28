import XCTest
@testable import NiceVideos

final class VLCFrameProgressTests: XCTestCase {
    func testAdvancingClockWithFrozenFramesWarnsAndRecovers() {
        var watch = VLCFrameProgress()
        for second in 0...15 {
            let warning = watch.stalled(frames: 3, media: 143 + Double(second),
                                        host: 60 + Double(second), playing: true)
            XCTAssertEqual(warning, second >= 12)
        }
        XCTAssertFalse(watch.stalled(frames: 4, media: 159, host: 76, playing: true))
    }

    func testSeeksPausesAndBufferingDoNotCountAsLostFrames() {
        var watch = VLCFrameProgress()
        for second in 0...10 {
            XCTAssertFalse(watch.stalled(frames: 0, media: Double(second), host: Double(second), playing: true))
        }
        XCTAssertFalse(watch.stalled(frames: 0, media: 140, host: 11, playing: true))
        XCTAssertFalse(watch.stalled(frames: 0, media: 140, host: 60, playing: false))
        for second in 0...18 {
            XCTAssertFalse(watch.stalled(frames: 0, media: 141, host: Double(61 + second), playing: true))
        }
        watch.reset()
        XCTAssertFalse(watch.stalled(frames: 0, media: 5, host: 100, playing: true))
    }
}
