import XCTest
@testable import NiceVideos

final class AfterglowFirstPictureWatchTests: XCTestCase {
    func testUndecodableTrackWithRunningAudioAndSeeksCannotPostponeFallback() {
        var watch = AfterglowFirstPictureWatch()
        watch.classifyTrack(decodable: false)
        for tick in 0...8 {
            if [2, 4, 6].contains(tick) { watch.seek() }
            XCTAssertEqual(watch.sample(at: Double(tick) * 0.5, active: true, playing: true),
                           tick == 8 ? .unsupportedTrack : nil)
        }
    }

    func testWaitingOrRepeatedUnfinishedSeeksStillHaveAForegroundDeadline() {
        var watch = AfterglowFirstPictureWatch()
        watch.classifyTrack(decodable: false)
        for tick in 0...30 {
            if tick % 3 == 0 { watch.seek() }
            XCTAssertEqual(watch.sample(at: Double(tick) * 0.5, active: true, playing: false),
                           tick == 30 ? .startupTimeout : nil)
        }
    }

    func testPausedAndBackgroundTimeAreExcludedAndAnActualPictureEndsTheTrial() {
        var watch = AfterglowFirstPictureWatch()
        watch.classifyTrack(decodable: false)
        for tick in 0...5 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: true, playing: true))
        }
        watch.suspend()
        for tick in 6...66 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: false, playing: false))
        }
        for tick in 67...69 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: true, playing: true))
        }
        watch.receivedPicture()
        watch.seek()
        for tick in 70...140 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: true, playing: true))
        }
    }

    func testDecodableInputKeepsNormalPrerollAfterASeek() {
        var watch = AfterglowFirstPictureWatch()
        watch.classifyTrack(decodable: true)
        for tick in 0...28 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: true, playing: true))
        }
        watch.seek()
        for tick in 29...54 {
            XCTAssertNil(watch.sample(at: Double(tick) * 0.5, active: true, playing: true))
        }
    }
}
