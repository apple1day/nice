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

    func testFivePresentedFramesPerSecondWithContinuingNativeLossRequestsOneReduction() {
        var watch = VLCFrameLossWatch()
        // Consecutive captures from the 1.3.5(16) phone report; Metal kept
        // presenting frames while VLC lost roughly twice as many as it showed.
        func observed(_ host: Double, _ clock: Double, _ decoded: Int32, _ displayed: Int32,
                      _ lost: Int32, _ offered: UInt64, _ delivered: UInt64) -> VLCFrameLossWatch.Sample {
            .init(clock: clock, host: host, decoded: decoded, displayed: displayed, lost: lost,
                  offered: offered, delivered: delivered, bufferMisses: 0, staleSource: 0, formatSetups: 1)
        }
        let rows = [observed(7.30, 4.86, 125, 24, 57, 25, 25),
                    observed(12.54, 10.10, 233, 53, 111, 54, 54),
                    observed(17.80, 15.36, 323, 77, 156, 78, 77)]
        XCTAssertFalse(watch.needsSmallerOutput(rows[0], nominalFrameRate: 59.94))
        XCTAssertFalse(watch.needsSmallerOutput(rows[1], nominalFrameRate: 59.94))
        XCTAssertTrue(watch.needsSmallerOutput(rows[2], nominalFrameRate: 59.94))
        XCTAssertEqual(watch.pattern, .sparse)
        let alreadyAtMinimum = VLCFrameLossWatch.State(active: true, seekable: true, remaining: 90,
                                                       outputEdge: 1280, reducedLimit: 1280, alreadyReduced: true)
        XCTAssertEqual(alreadyAtMinimum, .minimum)
    }

    func testLowCadenceNeedsKnownFastSourceNativeLossAndTwoConsecutiveWindows() {
        for fps in [0.0, 5.0, 59.94] {
            var watch = VLCFrameLossWatch()
            for t in 0...12 {
                // The 60-fps track loses pictures only in a single 3 s burst.
                let lost = fps > 50 ? Int32(min(t, 3) * 12) : Int32(t * 12)
                XCTAssertFalse(watch.needsSmallerOutput(sample(t, frames: UInt64(t * 5),
                    displayed: Int32(t * 5), lost: lost), nominalFrameRate: fps))
            }
        }
        var healthy = VLCFrameLossWatch(), paused = VLCFrameLossWatch()
        for t in 0...12 {
            XCTAssertFalse(healthy.needsSmallerOutput(sample(t, frames: UInt64(t * 24),
                displayed: Int32(t * 24), lost: Int32(t * 30)), nominalFrameRate: 60))
            if t.isMultiple(of: 4) { paused.reset() }
            XCTAssertFalse(paused.needsSmallerOutput(sample(t, frames: UInt64(t * 5),
                displayed: Int32(t * 5), lost: Int32(t * 12)), nominalFrameRate: 60))
        }
    }

    func testEffectivePlaybackIntentAndVisibilityGateNativeLossEvidence() {
        typealias Gate = VLCFrameLossWatch.Gate
        XCTAssertEqual(Gate(requested: true, preview: false, seeking: false, playing: true, background: false), .open)
        XCTAssertEqual(Gate(requested: false, preview: false, seeking: false, playing: true, background: false), .paused)
        XCTAssertEqual(Gate(requested: true, preview: false, seeking: true, playing: true, background: false), .seek)
        XCTAssertEqual(Gate(requested: true, preview: true, seeking: false, playing: true, background: false), .preview)
        XCTAssertEqual(Gate(requested: true, preview: false, seeking: false, playing: false, background: false), .notPlaying)
        XCTAssertEqual(Gate(requested: true, preview: false, seeking: false, playing: true, background: true), .background)
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

    func testMinimumOutputStillRecognizesTheHeldFirstFrameInTheLastTwoSeconds() {
        func sample(_ host: Double, _ clock: Double, _ decoded: Int32, _ lost: Int32) -> VLCFrameLossWatch.Sample {
            .init(clock: clock, host: host, decoded: decoded, displayed: 1, lost: lost,
                  offered: 1, delivered: 1, bufferMisses: 0, staleSource: 0, formatSetups: 1)
        }
        let duration = 15.05
        func state(at time: Double, reduced: Bool) -> VLCFrameLossWatch.State {
            .init(active: true, seekable: true, remaining: duration - time, outputEdge: reduced ? 1280 : 1600,
                  reducedLimit: 1280, alreadyReduced: reduced)
        }
        var watch = VLCFrameLossWatch()
        // Actual load #7 in build 17, including the clock slightly past duration.
        XCTAssertEqual(state(at: 10.90, reduced: true), .minimum)
        XCTAssertFalse(watch.needsSmallerOutput(sample(34.58, 10.90, 460, 112), nominalFrameRate: 59.94))
        XCTAssertEqual(state(at: 15.08, reduced: true), .minimum)
        XCTAssertTrue(watch.needsSmallerOutput(sample(38.85, 15.08, 825, 295), nominalFrameRate: 59.94))
        XCTAssertEqual(watch.pattern, .frozen)
        XCTAssertEqual(state(at: 15.08, reduced: false), .nearEnd, "The high-output route must not reopen near EOF")
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
