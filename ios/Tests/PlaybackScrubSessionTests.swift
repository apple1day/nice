import XCTest
@testable import NiceVideos

final class PlaybackScrubSessionTests: XCTestCase {
    func testNormalDragCommitsLatestDraftExactlyOnce() throws {
        var session = PlaybackScrubSession()
        XCTAssertFalse(session.isEditing)
        XCTAssertNil(session.draftSeconds)
        let token = try XCTUnwrap(session.begin(at: 10))
        XCTAssertTrue(session.update(25, token: token))
        XCTAssertEqual(session.finish(token: token), 25)
        XCTAssertFalse(session.isEditing)
        XCTAssertNil(session.draftSeconds)
        XCTAssertNil(session.finish(token: token))
    }

    func testTouchCancellationDiscardsDraftAndLateTouchUp() throws {
        var session = PlaybackScrubSession()
        let token = try XCTUnwrap(session.begin(at: 10))
        session.update(60, token: token)
        XCTAssertTrue(session.cancel())
        XCTAssertNil(session.draftSeconds)
        XCTAssertFalse(session.update(65, token: token))
        XCTAssertNil(session.finish(token: token))
    }

    func testDiscreteSeekCannotBeOverwrittenByOldTouchUp() throws {
        var session = PlaybackScrubSession()
        let old = try XCTUnwrap(session.begin(at: 10))
        session.update(90, token: old)
        session.cancel() // Navigation / seek / pause / fullscreen first cancels.
        var committedSeeks = [40.0] // The subsequent discrete seek already ran.
        session.update(95, token: old)
        if let lateTarget = session.finish(token: old) { committedSeeks.append(lateTarget) }
        XCTAssertEqual(committedSeeks, [40])
    }

    func testOldClipReleaseCannotCommitOrEndNewClipsDrag() throws {
        var session = PlaybackScrubSession()
        let old = try XCTUnwrap(session.begin(at: 300))
        session.cancel()
        let current = try XCTUnwrap(session.begin(at: 5))
        session.update(15, token: current)
        XCTAssertFalse(session.update(350, token: old))
        XCTAssertNil(session.finish(token: old))
        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(session.draftSeconds, 15)
        XCTAssertEqual(session.finish(token: current), 15)
    }

    func testNewTouchReplacesAnOrphanedSessionWithoutWaitingForTimeout() throws {
        var session = PlaybackScrubSession()
        let abandoned = try XCTUnwrap(session.begin(at: 10))
        let current = try XCTUnwrap(session.begin(at: 20))
        XCTAssertNotEqual(abandoned, current)
        XCTAssertNil(session.finish(token: abandoned))
        XCTAssertEqual(session.finish(token: current), 20)
    }

    func testRepeatedCancellationIsIdempotent() throws {
        var session = PlaybackScrubSession()
        let old = try XCTUnwrap(session.begin(at: 10))
        XCTAssertTrue(session.cancel())
        XCTAssertFalse(session.cancel())
        XCTAssertFalse(session.cancel())
        XCTAssertNil(session.finish(token: old))
        let next = try XCTUnwrap(session.begin(at: 20))
        XCTAssertEqual(session.finish(token: next), 20)
    }

    func testInvalidValuesNeverBecomeASeekTarget() throws {
        var session = PlaybackScrubSession()
        XCTAssertNil(session.begin(at: .nan))
        XCTAssertNil(session.begin(at: .infinity))
        XCTAssertFalse(session.isEditing)
        let token = try XCTUnwrap(session.begin(at: 10))
        XCTAssertFalse(session.update(.nan, token: token))
        XCTAssertFalse(session.update(-.infinity, token: token))
        XCTAssertEqual(session.finish(token: token), 10)
    }

    func testNegativeDraftClampsToStart() throws {
        var session = PlaybackScrubSession()
        let token = try XCTUnwrap(session.begin(at: -10))
        XCTAssertEqual(session.draftSeconds, 0)
        session.update(-25, token: token)
        XCTAssertEqual(session.finish(token: token), 0)
    }

    func testCancellationRestoresAutoHideWithoutAcceptingLateCommit() throws {
        var controls = PlaybackControlsState()
        var session = PlaybackScrubSession()
        controls.setPlaying(true, at: 0)
        let token = try XCTUnwrap(session.begin(at: 10))
        controls.setScrubbing(session.isEditing, at: 1)
        controls.hideIfDue(at: 30, deadline: 4)
        XCTAssertTrue(controls.isVisible)
        session.cancel()
        controls.setScrubbing(session.isEditing, at: 31)
        XCTAssertEqual(controls.hideDeadline, 35)
        XCTAssertNil(session.finish(token: token))
        controls.hideIfDue(at: 35, deadline: 35)
        XCTAssertFalse(controls.isVisible)
    }

    func testLongDragRemainsActiveUntilExplicitEnd() throws {
        var controls = PlaybackControlsState()
        var session = PlaybackScrubSession()
        controls.setPlaying(true, at: 0)
        let token = try XCTUnwrap(session.begin(at: 10))
        controls.setScrubbing(true, at: 1)
        for time in [5.0, 60, 120, 600] {
            session.update(time, token: token)
            controls.hideIfDue(at: time, deadline: 4)
            XCTAssertTrue(controls.isVisible)
            XCTAssertTrue(session.isEditing)
        }
        XCTAssertEqual(session.finish(token: token), 600)
        controls.setScrubbing(false, at: 601)
        XCTAssertEqual(controls.hideDeadline, 605)
    }
}
