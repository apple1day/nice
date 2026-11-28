import XCTest
@testable import NiceVideos

final class AppleVideoFrameWatchTests: XCTestCase {
    func testFrozenFrameAfterFirstRebuildsOnceThenRequestsDecoderFallback() {
        var watch = AppleVideoFrameWatch()
        for second in 0..<9 {
            let action = watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: 37, fps: 60)
            XCTAssertEqual(action, second == 8 ? .rebuildOutput : nil)
        }
        // The replacement output starts with a new sequence. It also freezes.
        for second in 9...17 {
            let action = watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: 1, fps: 60)
            XCTAssertEqual(action, second == 17 ? .fail : nil)
        }
    }

    func testRebuiltOutputCanResumeAtSamePlaybackTimeWithoutFallingBack() {
        var watch = AppleVideoFrameWatch()
        for second in 0...6 {
            let action = watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: false, sequence: 0, fps: nil)
            XCTAssertEqual(action, second == 6 ? .rebuildOutput : nil)
        }
        for second in 7...45 {
            XCTAssertNil(watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: UInt64(second), fps: 30))
        }
    }

    func testPauseBufferingOrSeekDoesNotSpendTheRecoveryBudget() {
        var watch = AppleVideoFrameWatch()
        for second in 0...6 {
            XCTAssertNil(watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: 1, fps: 30))
        }
        XCTAssertNil(watch.sample(clock: 7, expectingVideo: false, projected: true, hasImage: true, sequence: 1, fps: 30))
        for second in 600...605 {
            XCTAssertNil(watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: 1, fps: 30))
        }
        for _ in 0...50 {
            XCTAssertNil(watch.sample(clock: 605, expectingVideo: true, projected: true,
                                      hasImage: true, sequence: 1, fps: 30))
        }
        XCTAssertNil(watch.sample(clock: 100, expectingVideo: true, projected: true, hasImage: true, sequence: 1, fps: 30))
        XCTAssertNil(watch.sample(clock: 900, expectingVideo: true, projected: true, hasImage: true, sequence: 1, fps: 30))
        XCTAssertFalse(watch.rebuilt)
    }

    func testSparseVideoAndOrdinaryReadyLayerDoNotCountAsFrozenVR() {
        var watch = AppleVideoFrameWatch()
        for second in 0...50 {
            let sequence = UInt64(second / 10 + 1)
            XCTAssertNil(watch.sample(clock: Double(second), expectingVideo: true, projected: true,
                                      hasImage: true, sequence: sequence, fps: 0.1))
        }
        for second in 51...80 {
            XCTAssertNil(watch.sample(clock: Double(second), expectingVideo: true, projected: false,
                                      hasImage: true, sequence: 0, fps: 60))
        }
    }
}
