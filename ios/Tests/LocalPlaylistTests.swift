import XCTest
@testable import NiceVideos

final class LocalPlaylistTests: XCTestCase {
    func testUpMeansPreviousAndDownMeansNext() {
        XCTAssertEqual(PlaylistSwipe.direction(horizontal: 0, vertical: -100), .previous)
        XCTAssertEqual(PlaylistSwipe.direction(horizontal: 0, vertical: 100), .next)
    }
    func testSmallDragsAndHorizontalScrubsDoNotSwitch() {
        XCTAssertNil(PlaylistSwipe.direction(horizontal: 0, vertical: -63))
        XCTAssertNil(PlaylistSwipe.direction(horizontal: 0, vertical: 63))
        XCTAssertNil(PlaylistSwipe.direction(horizontal: 100, vertical: 20))
        XCTAssertNil(PlaylistSwipe.direction(horizontal: 100, vertical: 100))
        XCTAssertNil(PlaylistSwipe.direction(horizontal: 100, vertical: 135))
    }
    func testThresholdAndVerticalDominance() {
        XCTAssertEqual(PlaylistSwipe.direction(horizontal: 10, vertical: -64), .previous)
        XCTAssertEqual(PlaylistSwipe.direction(horizontal: 100, vertical: 136), .next)
    }
    func testInvalidCoordinatesAreIgnored() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(PlaylistSwipe.direction(horizontal: value, vertical: 100))
            XCTAssertNil(PlaylistSwipe.direction(horizontal: 0, vertical: value))
        }
    }
    func testKeepsLocalOrderAndStartsAtTappedVideo() {
        let list = LocalPlaybackPlaylist(ids: ["C", "A", "B"], currentID: "A")
        XCTAssertEqual(list.ids, ["C", "A", "B"])
        XCTAssertEqual(list.candidates(.previous, available: Set(list.ids)), ["C"])
        XCTAssertEqual(list.candidates(.next, available: Set(list.ids)), ["B"])
    }
    func testNoWrapAtEitherBoundary() {
        var list = LocalPlaybackPlaylist(ids: ["A", "B", "C"], currentID: "A")
        XCTAssertTrue(list.candidates(.previous, available: Set(list.ids)).isEmpty)
        list.select("C")
        XCTAssertTrue(list.candidates(.next, available: Set(list.ids)).isEmpty)
    }
    func testDeletedVideosAreSkippedWithoutIndexDrift() {
        let list = LocalPlaybackPlaylist(ids: ["A", "B", "C", "D", "E"], currentID: "D")
        XCTAssertEqual(list.candidates(.previous, available: ["A", "D", "E"]), ["A"])
        XCTAssertEqual(list.candidates(.next, available: ["A", "D", "E"]), ["E"])
    }
    func testPreviousCandidatesAreNearestFirst() {
        let list = LocalPlaybackPlaylist(ids: ["A", "B", "C", "D"], currentID: "D")
        XCTAssertEqual(list.candidates(.previous, available: Set(list.ids)), ["C", "B", "A"])
    }
    func testNewDownloadsDoNotReorderCurrentSession() {
        let list = LocalPlaybackPlaylist(ids: ["A", "B"], currentID: "A")
        XCTAssertEqual(list.visibleIDs(available: ["C", "B", "A"]), ["A", "B"])
        XCTAssertEqual(list.candidates(.next, available: ["A", "B", "C"]), ["B"])
    }
    func testDuplicateIDsAreDeduplicatedNotFilenames() {
        let list = LocalPlaybackPlaylist(ids: ["server1/demo", "server1/demo", "server2/demo"], currentID: "server1/demo")
        XCTAssertEqual(list.ids, ["server1/demo", "server2/demo"])
    }
    func testCurrentAnchorSurvivesMissingAvailability() {
        let list = LocalPlaybackPlaylist(ids: ["A", "B", "C"], currentID: "B")
        XCTAssertEqual(list.candidates(.previous, available: ["A", "C"]), ["A"])
        XCTAssertEqual(list.candidates(.next, available: ["A", "C"]), ["C"])
    }
    func testSingleVideoHasNoNeighbors() {
        let list = LocalPlaybackPlaylist(ids: [], currentID: "A")
        XCTAssertEqual(list.ids, ["A"])
        XCTAssertTrue(list.candidates(.previous, available: ["A"]).isEmpty)
        XCTAssertTrue(list.candidates(.next, available: ["A"]).isEmpty)
    }
    func testUnknownSelectionDoesNotChangeCurrentID() {
        var list = LocalPlaybackPlaylist(ids: ["A", "B"], currentID: "A")
        XCTAssertFalse(list.select("X"))
        XCTAssertEqual(list.currentID, "A")
        XCTAssertTrue(list.select("B"))
        XCTAssertTrue(list.select("B"))
        XCTAssertEqual(list.currentID, "B")
    }
    func testSwipingKeepsHUDVisibleUntilReleased() {
        var controls = PlaybackControlsState()
        controls.setPlaying(true, at: 0)
        controls.setNavigating(true, at: 2)
        XCTAssertNil(controls.hideDeadline)
        controls.hideIfDue(at: 100, deadline: 4)
        XCTAssertTrue(controls.isVisible)
        controls.setNavigating(false, at: 100)
        XCTAssertEqual(controls.hideDeadline, 104)
    }
    func testChangingClipRestartsTimerButRetainsFullscreen() {
        var controls = PlaybackControlsState()
        controls.toggleFullscreen(at: 0)
        controls.setPlaying(true, at: 0)
        controls.setPlaying(false, at: 2)
        controls.setScrubbing(false, at: 2)
        controls.setNavigating(false, at: 2)
        controls.interacted(at: 2)
        XCTAssertTrue(controls.isFullscreen)
        XCTAssertTrue(controls.isVisible)
        XCTAssertNil(controls.hideDeadline)
        controls.setPlaying(true, at: 5)
        XCTAssertEqual(controls.hideDeadline, 9)
        controls.hideIfDue(at: 6, deadline: 4)
        XCTAssertTrue(controls.isVisible)
    }
    func testBackgroundAndCloseClearSwipeState() {
        var controls = PlaybackControlsState()
        controls.setPlaying(true, at: 0)
        controls.setNavigating(true, at: 1)
        controls.setSceneActive(false, at: 2)
        XCTAssertFalse(controls.isNavigating)
        XCTAssertNil(controls.hideDeadline)
        controls.setNavigating(true, at: 3)
        controls.stop()
        XCTAssertFalse(controls.isNavigating)
        XCTAssertNil(controls.hideDeadline)
    }
}
