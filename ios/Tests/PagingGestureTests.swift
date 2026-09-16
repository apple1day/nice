import XCTest
@testable import NiceVideos

final class PagingGestureTests: XCTestCase {
    func testInteractivePageFollowsFingerWhenNeighborExists() {
        XCTAssertEqual(
            PlaylistSwipe.interactiveOffset(
                horizontal: 5, vertical: -180, viewportHeight: 800,
                hasPrevious: true, hasNext: true
            ),
            -180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PlaylistSwipe.interactiveOffset(
                horizontal: 5, vertical: 220, viewportHeight: 800,
                hasPrevious: true, hasNext: true
            ),
            220,
            accuracy: 0.001
        )
    }

    func testBoundaryUsesRubberBandInsteadOfHardStop() {
        let up = PlaylistSwipe.interactiveOffset(
            horizontal: 0, vertical: -200, viewportHeight: 800,
            hasPrevious: false, hasNext: true
        )
        let down = PlaylistSwipe.interactiveOffset(
            horizontal: 0, vertical: 200, viewportHeight: 800,
            hasPrevious: true, hasNext: false
        )
        XCTAssertEqual(up, -36, accuracy: 0.001)
        XCTAssertEqual(down, 36, accuracy: 0.001)
    }

    func testHorizontalMovementDoesNotMoveVideoPage() {
        XCTAssertEqual(
            PlaylistSwipe.interactiveOffset(
                horizontal: 200, vertical: 80, viewportHeight: 800,
                hasPrevious: true, hasNext: true
            ),
            0
        )
    }

    func testDeliberatePageDragCommitsAtViewportRelativeThreshold() {
        XCTAssertEqual(
            PlaylistSwipe.pagingDirection(
                horizontal: 5, vertical: -130, predictedVertical: -150, viewportHeight: 800
            ),
            .previous
        )
        XCTAssertEqual(
            PlaylistSwipe.pagingDirection(
                horizontal: 5, vertical: 130, predictedVertical: 150, viewportHeight: 800
            ),
            .next
        )
    }

    func testQuickFlickCommitsWithoutLongDrag() {
        XCTAssertEqual(
            PlaylistSwipe.pagingDirection(
                horizontal: 4, vertical: -55, predictedVertical: -320, viewportHeight: 800
            ),
            .previous
        )
        XCTAssertEqual(
            PlaylistSwipe.pagingDirection(
                horizontal: 4, vertical: 55, predictedVertical: 320, viewportHeight: 800
            ),
            .next
        )
    }

    func testShortSlowDragBouncesBack() {
        XCTAssertNil(
            PlaylistSwipe.pagingDirection(
                horizontal: 4, vertical: 55, predictedVertical: 70, viewportHeight: 800
            )
        )
    }

    func testCrossAxisGestureDoesNotPage() {
        XCTAssertNil(
            PlaylistSwipe.pagingDirection(
                horizontal: 180, vertical: 100, predictedVertical: 260, viewportHeight: 800
            )
        )
    }

    func testInvalidPagingCoordinatesAreIgnored() {
        XCTAssertNil(
            PlaylistSwipe.pagingDirection(
                horizontal: 0, vertical: .nan, predictedVertical: 100, viewportHeight: 800
            )
        )
        XCTAssertEqual(
            PlaylistSwipe.interactiveOffset(
                horizontal: 0, vertical: .infinity, viewportHeight: 800,
                hasPrevious: true, hasNext: true
            ),
            0
        )
    }
}
