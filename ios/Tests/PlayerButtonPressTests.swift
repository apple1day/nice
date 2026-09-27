import XCTest
@testable import NiceVideos

final class PlayerButtonPressTests: XCTestCase {
    func testPressBeforeDeadlinePreventsHideUntilRelease() throws {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        let deadline = try XCTUnwrap(state.hideDeadline)
        let button = UUID()
        state.setControlPressed(button, pressed: true, at: 3.99)
        state.hideIfDue(at: 5, deadline: deadline)
        XCTAssertTrue(state.isPressingControl)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
        state.setControlPressed(button, pressed: false, at: 6)
        XCTAssertEqual(state.hideDeadline, 10)
        state.hideIfDue(at: 9, deadline: deadline)
        XCTAssertTrue(state.isVisible)
        state.hideIfDue(at: 10, deadline: 10)
        XCTAssertFalse(state.isVisible)
    }

    func testTwoButtonsReleaseIndependently() {
        var state = PlaybackControlsState()
        let first = UUID(), second = UUID()
        state.setPlaying(true, at: 0)
        state.setControlPressed(first, pressed: true, at: 1)
        state.setControlPressed(second, pressed: true, at: 2)
        state.setControlPressed(first, pressed: false, at: 3)
        XCTAssertTrue(state.isPressingControl)
        XCTAssertNil(state.hideDeadline)
        state.setControlPressed(second, pressed: false, at: 4)
        XCTAssertFalse(state.isPressingControl)
        XCTAssertEqual(state.hideDeadline, 8)
    }

    func testRepeatedReleaseCannotPostponeNewDeadline() {
        var state = PlaybackControlsState()
        let button = UUID()
        state.setPlaying(true, at: 0)
        state.setControlPressed(button, pressed: true, at: 1)
        state.setControlPressed(button, pressed: false, at: 2)
        for _ in 0..<100 { state.setControlPressed(button, pressed: false, at: 20) }
        XCTAssertEqual(state.hideDeadline, 6)
    }

    func testBackgroundAndLatePressDoNotLeaveControlsLocked() {
        var state = PlaybackControlsState()
        let button = UUID()
        state.setPlaying(true, at: 0)
        state.setControlPressed(button, pressed: true, at: 1)
        state.setSceneActive(false, at: 2)
        state.setControlPressed(button, pressed: true, at: 3)
        state.setControlPressed(button, pressed: false, at: 4)
        XCTAssertFalse(state.isPressingControl)
        XCTAssertNil(state.hideDeadline)
        state.setPlaying(false, at: 4)
        state.setSceneActive(true, at: 10)
        state.setPlaying(true, at: 11)
        XCTAssertEqual(state.hideDeadline, 15)
    }

    func testClosedControlsIgnoreLatePress() {
        var state = PlaybackControlsState()
        let button = UUID()
        state.setPlaying(true, at: 0)
        state.setControlPressed(button, pressed: true, at: 1)
        state.stop()
        state.setControlPressed(button, pressed: true, at: 3)
        state.setControlPressed(button, pressed: false, at: 4)
        XCTAssertFalse(state.isPressingControl)
        XCTAssertNil(state.hideDeadline)
    }

    func testClipSwitchClearsOnlyOldHoldsAndOldReleaseIsHarmless() {
        var state = PlaybackControlsState()
        let old = UUID(), next = UUID()
        state.setPlaying(true, at: 0)
        state.setControlPressed(old, pressed: true, at: 1)
        state.resetControlPresses(at: 2)
        state.setControlPressed(next, pressed: true, at: 3)
        state.setControlPressed(old, pressed: false, at: 4)
        XCTAssertTrue(state.isPressingControl)
        XCTAssertNil(state.hideDeadline)
        state.setControlPressed(next, pressed: false, at: 5)
        XCTAssertEqual(state.hideDeadline, 9)
    }

    func testButtonReleaseDoesNotClearSliderTracking() {
        var state = PlaybackControlsState()
        let button = UUID()
        state.setPlaying(true, at: 0)
        state.setScrubbing(true, at: 1)
        state.setControlPressed(button, pressed: true, at: 2)
        state.setControlPressed(button, pressed: false, at: 3)
        XCTAssertTrue(state.isScrubbing)
        XCTAssertNil(state.hideDeadline)
        state.setScrubbing(false, at: 4)
        XCTAssertEqual(state.hideDeadline, 8)
    }

    func testSurfaceTapCannotHidePressedControls() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setControlPressed(UUID(), pressed: true, at: 1)
        state.surfaceTapped(at: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testPausedAndVoiceOverPressesRemainVisible() {
        for voiceOver in [false, true] {
            var state = PlaybackControlsState()
            state.setVoiceOverEnabled(voiceOver, at: 0)
            let button = UUID()
            state.setControlPressed(button, pressed: true, at: 1)
            state.setControlPressed(button, pressed: false, at: 2)
            XCTAssertTrue(state.isVisible)
            XCTAssertNil(state.hideDeadline)
        }
    }
}
