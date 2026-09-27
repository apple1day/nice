import XCTest
@testable import NiceVideos

final class PlaybackControlsTests: XCTestCase {
    func testInitiallyVisibleWithoutTimer() {
        let state = PlaybackControlsState()
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.isFullscreen)
        XCTAssertNil(state.hideDeadline)
    }

    func testPlayingHidesAfterFourSecondsNotBefore() throws {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 10)
        let deadline = try XCTUnwrap(state.hideDeadline)
        XCTAssertEqual(deadline, 14)
        state.hideIfDue(at: 13.99, deadline: deadline)
        XCTAssertTrue(state.isVisible)
        state.hideIfDue(at: 14, deadline: deadline)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testTapRevealsWithFreshDeadline() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.hideIfDue(at: 4, deadline: 4)
        state.surfaceTapped(at: 20)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.hideDeadline, 24)
    }

    func testTapVisiblePlayingSurfaceHidesImmediately() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.surfaceTapped(at: 1)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testInteractionCancelsOldDeadline() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.interacted(at: 3)
        state.hideIfDue(at: 4, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.hideDeadline, 7)
        state.hideIfDue(at: 7, deadline: 7)
        XCTAssertFalse(state.isVisible)
    }

    func testPlaybackTicksDoNotKeepControlsVisibleForever() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        for index in 1...30 { state.setPlaying(true, at: Double(index) / 10) }
        XCTAssertEqual(state.hideDeadline, 4)
        state.hideIfDue(at: 4, deadline: 4)
        state.setPlaying(true, at: 5)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testPauseRevealsAndNeverHides() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.hideIfDue(at: 4, deadline: 4)
        state.setPlaying(false, at: 5)
        state.surfaceTapped(at: 6)
        state.hideIfDue(at: 100, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testResumeStartsNewTimer() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setPlaying(false, at: 2)
        state.setPlaying(true, at: 20)
        XCTAssertEqual(state.hideDeadline, 24)
    }

    func testDraggingKeepsSliderVisibleRegardlessOfElapsedTime() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setScrubbing(true, at: 3)
        state.hideIfDue(at: 100, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.isScrubbing)
        XCTAssertNil(state.hideDeadline)
    }

    func testReleaseSliderStartsFullDelay() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setScrubbing(true, at: 1)
        state.setScrubbing(false, at: 20)
        XCTAssertEqual(state.hideDeadline, 24)
        state.hideIfDue(at: 23, deadline: 24)
        XCTAssertTrue(state.isVisible)
    }

    func testPausedScrubDoesNotStartTimer() {
        var state = PlaybackControlsState()
        state.setScrubbing(true, at: 1)
        state.setScrubbing(false, at: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
    }

    func testFullscreenTogglesLayoutWithoutChangingPlaybackState() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.toggleFullscreen(at: 2)
        XCTAssertTrue(state.isFullscreen)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.hideDeadline, 6)
        state.toggleFullscreen(at: 3)
        XCTAssertFalse(state.isFullscreen)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.hideDeadline, 7)
    }

    func testFullscreenWhenPausedStaysVisible() {
        var state = PlaybackControlsState()
        state.toggleFullscreen(at: 1)
        state.surfaceTapped(at: 2)
        XCTAssertTrue(state.isFullscreen)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.hideDeadline)
    }

    func testFullscreenTimerHasSameBehavior() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.toggleFullscreen(at: 1)
        state.hideIfDue(at: 5, deadline: 5)
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.isFullscreen)
        state.surfaceTapped(at: 7)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.hideDeadline, 11)
    }

    func testBackgroundCancelsTimerAndScrub() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setScrubbing(true, at: 1)
        state.setSceneActive(false, at: 2)
        state.hideIfDue(at: 30, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.isScrubbing)
        XCTAssertNil(state.hideDeadline)
    }

    func testForegroundAfterPauseDoesNotStartPlaybackOrTimer() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setSceneActive(false, at: 1)
        state.setPlaying(false, at: 1)
        state.setSceneActive(true, at: 50)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.hideDeadline)
    }

    func testVoiceOverDisablesAutomaticAndTapHiding() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setVoiceOverEnabled(true, at: 1)
        state.surfaceTapped(at: 10)
        state.hideIfDue(at: 100, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
        state.setVoiceOverEnabled(false, at: 110)
        XCTAssertEqual(state.hideDeadline, 114)
    }

    func testDeletionErrorAlertBlocksTimeoutAndRestartsAfterDismiss() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.setPresentingAlert(true, at: 2)
        state.hideIfDue(at: 20, deadline: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.hideDeadline)
        state.setPresentingAlert(false, at: 21)
        XCTAssertEqual(state.hideDeadline, 25)
    }

    func testClosingIgnoresLateTimerCallback() {
        var state = PlaybackControlsState()
        state.setPlaying(true, at: 0)
        state.stop()
        state.hideIfDue(at: 10, deadline: 4)
        XCTAssertNil(state.hideDeadline)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.isPlaying)
    }

    func testCustomDelayAndInvalidDelayFallback() {
        var custom = PlaybackControlsState(hideDelay: 6)
        custom.setPlaying(true, at: 10)
        XCTAssertEqual(custom.hideDeadline, 16)
        for delay in [0, -1, .nan, .infinity, 61] as [Double] {
            XCTAssertEqual(PlaybackControlsState(hideDelay: delay).hideDelay, 4)
        }
    }
}
