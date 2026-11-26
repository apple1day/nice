import XCTest
@testable import NiceVideos

final class SeekResponsivenessTests: XCTestCase {
    func testLatestScrubIsIssuedAfterStartupAndAnOldClockCannotConfirmIt() {
        var gate = SeekFeedbackGate()
        for target in [343.3, 585.2, 726.25, 932.59] {
            gate.begin(target: target, now: 1)
            XCTAssertEqual(gate.sample(182.05, at: 1.1, seekable: false), .none)
        }
        XCTAssertEqual(gate.sample(182.05, at: 1.2), .issue(932.59))
        XCTAssertEqual(gate.sample(932.59, at: 1.4), .none)
        XCTAssertEqual(gate.sample(182.05, at: 1.8), .none)
        XCTAssertEqual(gate.target, 932.59)
        XCTAssertEqual(gate.sample(932.59, at: 2.0), .none)
        XCTAssertEqual(gate.sample(932.86, at: 2.3), .none)
        XCTAssertNil(gate.target)
    }

    func testSupersedingAnIssuedSeekWithTheCurrentPositionStillSeeks() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 585, now: 0)
        XCTAssertEqual(gate.sample(182, at: 0), .issue(585))
        gate.begin(target: 182, now: 0.1)
        XCTAssertEqual(gate.sample(182, at: 0.2), .issue(182))
        XCTAssertEqual(gate.sample(585, at: 0.3), .none)
        XCTAssertEqual(gate.target, 182)
    }

    func testLostSeekReopensOnceAtLatestTargetThenReleasesSeekGate() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 932.59, now: 0)
        XCTAssertEqual(gate.sample(182, at: 0), .issue(932.59))
        for tick in 1...5 { XCTAssertEqual(gate.sample(182, at: Double(tick)), .none) }
        XCTAssertEqual(gate.sample(182, at: 6), .reopen(932.59))
        gate.begin(target: 932.59, now: 6, verifyingReopen: true)
        for tick in 7...15 { XCTAssertEqual(gate.sample(182, at: Double(tick)), .none) }
        XCTAssertEqual(gate.sample(182, at: 16), .reportFailure(932.59))
        XCTAssertNil(gate.target)
        XCTAssertEqual(gate.sample(182, at: 17), .none)
    }

    func testUnsupportedSeekReadinessAndBackgroundDoNotLoseTheTarget() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 900, now: 0)
        for tick in 1...3 { XCTAssertEqual(gate.sample(182, at: Double(tick), seekable: false), .none) }
        XCTAssertEqual(gate.sample(182, at: 4, seekable: false, foreground: false), .none)
        XCTAssertEqual(gate.sample(182, at: 5400, seekable: false), .none)
        XCTAssertEqual(gate.sample(182, at: 5401, seekable: false), .none)
        XCTAssertEqual(gate.sample(182, at: 5402, seekable: false), .none)
        XCTAssertEqual(gate.sample(182, at: 5403, seekable: false), .reopen(900))
    }

    func testPausedReopenConfirmsWithoutPlayingOrReissuingSeek() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 726.25, now: 0, verifyingReopen: true)
        XCTAssertEqual(gate.sample(0, at: 0.1, playing: false), .none)
        XCTAssertEqual(gate.sample(726.25, at: 0.5, playing: false), .none)
        XCTAssertEqual(gate.sample(726.25, at: 0.8, playing: false), .none)
        XCTAssertNil(gate.target)
    }
}

private extension SeekFeedbackGate {
    mutating func sample(_ raw: Double, at now: TimeInterval, seekable: Bool = true,
                         playing: Bool = true, foreground: Bool = true) -> Action {
        update(raw: raw, duration: 2567.89, seekable: seekable, playing: playing,
               ended: false, foreground: foreground, now: now)
    }
}
