import XCTest
@testable import NiceVideos

final class VLCFrameLossWatchTests: XCTestCase {
    private func sample(_ second: Int, clock: Double? = nil, frames: UInt64 = 1,
                        displayed: Int32 = 1, lost: Int32? = nil,
                        misses: UInt64 = 0, stale: UInt64 = 0) -> VLCFrameLossWatch.Sample {
        .init(clock: clock ?? Double(second), host: Double(second), decoded: Int32(70 * second),
              displayed: displayed, lost: lost ?? Int32(35 * second), offered: frames, delivered: frames,
              bufferMisses: misses, staleSource: stale, formatSetups: 1)
    }

    func testFirstFrameDeliveredWithSustainedNativeLossRequestsRecovery() {
        var watch = VLCFrameLossWatch()
        for second in 1...5 {
            XCTAssertEqual(watch.needsSmallerOutput(sample(second)), second == 5)
        }
    }

    func testHealthyVideoSparseVideoAndAStaleVoutDoNotRequestRecovery() {
        var moving = VLCFrameLossWatch(), sparse = VLCFrameLossWatch(), rejected = VLCFrameLossWatch()
        var exhaustedPool = VLCFrameLossWatch(), waitingForFirstFrame = VLCFrameLossWatch()
        for second in 1...15 {
            XCTAssertFalse(moving.needsSmallerOutput(sample(second, frames: UInt64(second))))
            XCTAssertFalse(sparse.needsSmallerOutput(sample(second, lost: 2)))
            XCTAssertFalse(rejected.needsSmallerOutput(sample(second, displayed: Int32(second), stale: UInt64(second))))
            XCTAssertFalse(exhaustedPool.needsSmallerOutput(sample(second, misses: UInt64(second))))
            XCTAssertFalse(waitingForFirstFrame.needsSmallerOutput(sample(second, frames: 0)))
        }
    }

    func testSparseAndRepeatedClockSamplesStillRecognizeNativeLoss() {
        var watch = VLCFrameLossWatch()
        XCTAssertFalse(watch.needsSmallerOutput(sample(35, clock: 818, lost: 25)))
        XCTAssertFalse(watch.needsSmallerOutput(sample(36, clock: 818, lost: 40)))
        XCTAssertTrue(watch.needsSmallerOutput(sample(40, clock: 823, lost: 190)))
        XCTAssertEqual(watch.observedMediaSeconds, 5)
    }

    func testBeforeFirstOutputRequiresFormatStableCountersAndIncreasingLoss() {
        var lostBeforeDisplay = VLCFrameLossWatch(), noLoss = VLCFrameLossWatch()
        for second in 1...5 {
            XCTAssertEqual(lostBeforeDisplay.needsSmallerOutput(sample(second, frames: 0, displayed: 0)), second == 5)
            XCTAssertFalse(noLoss.needsSmallerOutput(sample(second, frames: 0, displayed: 0, lost: 0)))
        }
    }

    func testLongUnobservedGapAndCounterResetDoNotTriggerRecovery() {
        var gap = VLCFrameLossWatch(), restarted = VLCFrameLossWatch()
        XCTAssertFalse(gap.needsSmallerOutput(sample(10)))
        XCTAssertFalse(gap.needsSmallerOutput(sample(20)))
        XCTAssertFalse(restarted.needsSmallerOutput(sample(10, lost: 200)))
        XCTAssertFalse(restarted.needsSmallerOutput(sample(15, lost: 40)))
    }

    func testMinimumCapAndIneligibleInputsAreDistinguishedInDiagnostics() {
        func state(_ edge: UInt32, remaining: Double = 20, active: Bool = true, seekable: Bool = true,
                   reduced: Bool = false) -> VLCFrameLossWatch.State {
            .init(active: active, seekable: seekable, remaining: remaining, outputEdge: edge,
                  reducedLimit: 1280, alreadyReduced: reduced)
        }
        XCTAssertEqual(state(0), .awaitingFormat)
        XCTAssertEqual(state(1600), .monitoring)
        XCTAssertEqual(state(1280), .smallOutput)
        XCTAssertEqual(state(1280, reduced: true), .minimum)
        XCTAssertEqual(state(1600, remaining: 0), .nearEnd)
        XCTAssertEqual(state(1600, active: false), .inactive)
        XCTAssertEqual(state(1600, seekable: false), .unseekable)
    }

    func testSeekAndPauseDiscardEarlierLossEvidence() {
        var watch = VLCFrameLossWatch()
        for second in 1...4 {
            XCTAssertFalse(watch.needsSmallerOutput(sample(second)))
        }
        XCTAssertFalse(watch.needsSmallerOutput(sample(5, clock: 100)))
        for second in 6...8 {
            XCTAssertFalse(watch.needsSmallerOutput(sample(second, clock: Double(95 + second))))
        }
        watch.reset()
        for second in 9...12 {
            XCTAssertFalse(watch.needsSmallerOutput(sample(second)))
        }
    }
}
