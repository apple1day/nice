import XCTest
@testable import NiceVideos

final class LibraryPoliciesTests: XCTestCase {
    private struct Entry { let id: Int; let date: Date? }
    private func order(_ entries: [Entry]) -> [Int] {
        LocalLibraryOrder.newestFirst(entries, completedAt: { $0.date }).map(\.id)
    }
    func testLegacyRecordsUseReverseSavedOrder() {
        XCTAssertEqual(order((0..<300).map { Entry(id: $0, date: nil) }), Array((0..<300).reversed()))
    }
    func testCompletionTimeWinsOverQueuePosition() {
        XCTAssertEqual(order([
            Entry(id: 1, date: Date(timeIntervalSince1970: 30)),
            Entry(id: 2, date: Date(timeIntervalSince1970: 10)),
            Entry(id: 3, date: Date(timeIntervalSince1970: 20))
        ]), [1, 3, 2])
    }
    func testNewCompletedDownloadsPrecedeLegacyWithoutInventingDates() {
        XCTAssertEqual(order([Entry(id: 1, date: nil), Entry(id: 2, date: nil),
                             Entry(id: 3, date: Date(timeIntervalSince1970: 100))]), [3, 2, 1])
    }
    func testEqualDatesHaveDeterministicReverseSavedOrder() {
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(order((0..<600).map { Entry(id: $0, date: date) }), Array((0..<600).reversed()))
    }
    func testEmptyAndSingleton() {
        XCTAssertTrue(order([]).isEmpty)
        XCTAssertEqual(order([Entry(id: 1, date: nil)]), [1])
    }
    func testInvalidDatesAreHandledAsLegacy() {
        XCTAssertEqual(order([Entry(id: 1, date: Date(timeIntervalSince1970: .infinity)),
                             Entry(id: 2, date: Date(timeIntervalSince1970: 100)),
                             Entry(id: 3, date: nil)]), [2, 3, 1])
    }
    func testOpenWithoutPlayingIsNotWatched() {
        var gate = PlaybackWatchGate()
        XCTAssertFalse(gate.consume(isPlaying: false, hasVideo: false, allowed: true))
        XCTAssertFalse(gate.consume(isPlaying: false, hasVideo: true, allowed: true))
        XCTAssertFalse(gate.recorded)
    }
    func testPlayingWithoutVideoOutputIsNotWatched() {
        var gate = PlaybackWatchGate()
        XCTAssertFalse(gate.consume(isPlaying: true, hasVideo: false, allowed: true))
    }
    func testPausedOrClosedSessionDoesNotMarkLateFrame() {
        var gate = PlaybackWatchGate()
        XCTAssertFalse(gate.consume(isPlaying: true, hasVideo: true, allowed: false))
        XCTAssertTrue(gate.consume(isPlaying: true, hasVideo: true, allowed: true))
    }
    func testWatchRecordedOnceDespiteManyPlaybackCallbacks() {
        var gate = PlaybackWatchGate()
        XCTAssertTrue(gate.consume(isPlaying: true, hasVideo: true, allowed: true))
        for _ in 0..<1000 {
            XCTAssertFalse(gate.consume(isPlaying: true, hasVideo: true, allowed: true))
        }
    }
}
