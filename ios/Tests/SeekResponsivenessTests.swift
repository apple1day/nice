import XCTest
@testable import NiceVideos

final class SeekResponsivenessTests: XCTestCase {
    func testStalePreSeekTimesDoNotPullSliderBack() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 60, now: 10)

        XCTAssertEqual(gate.displayedSeconds(raw: 12, now: 10.1), 60)
        XCTAssertEqual(gate.displayedSeconds(raw: 25, now: 10.3), 60)
        XCTAssertEqual(gate.target, 60)
    }

    func testGateReleasesWhenVLCReachesTargetNeighborhood() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 60, now: 10)

        XCTAssertEqual(gate.displayedSeconds(raw: 59.4, now: 10.4), 59.4)
        XCTAssertNil(gate.target)
        XCTAssertEqual(gate.displayedSeconds(raw: 60.2, now: 10.5), 60.2)
    }

    func testGateExpiresInsteadOfMaskingPlaybackForever() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 60, now: 10, timeout: 1.25)

        XCTAssertEqual(gate.displayedSeconds(raw: 20, now: 11.24), 60)
        XCTAssertEqual(gate.displayedSeconds(raw: 21, now: 11.25), 21)
        XCTAssertNil(gate.target)
    }

    func testNewSeekReplacesEarlierTarget() {
        var gate = SeekFeedbackGate()
        gate.begin(target: 20, now: 1)
        gate.begin(target: 80, now: 1.1)

        XCTAssertEqual(gate.displayedSeconds(raw: 20, now: 1.2), 80)
        XCTAssertEqual(gate.target, 80)
    }
}
