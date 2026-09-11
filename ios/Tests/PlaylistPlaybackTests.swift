import XCTest
import UIKit
@testable import NiceVideos

private final class PlaylistTestEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var loaded: [URL] = []
    var playCount = 0
    var stopCount = 0
    var seeks: [Double] = []
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws { loaded.append(fileURL) }
    func play() { playCount += 1 }
    func pause() {}
    func seek(to seconds: Double) { seeks.append(seconds) }
    func stop() { stopCount += 1 }
    func tick(_ seconds: Double) {
        onUpdate?(PlaybackSnapshot(phase: .playing, seconds: seconds, duration: 100, seekable: true, hasVideo: true))
    }
}
private final class PlaylistEnginePool {
    var engines: [PlaylistTestEngine] = []
    var previousWasStoppedBeforeCreation: [Bool] = []
    func make() -> LocalPlaybackEngine {
        if let previous = engines.last { previousWasStoppedBeforeCreation.append(previous.stopCount == 1) }
        let engine = PlaylistTestEngine()
        engines.append(engine)
        return engine
    }
}
private struct PlaylistFixture {
    let disk: LocalStorage
    let records: [DownloadRecord]
    let defaults: UserDefaults
    let store: VideoStore
    let anchor: PlaybackRequest
    let model: PlaylistPlaybackModel
    let pool: PlaylistEnginePool
}

final class PlaylistPlaybackTests: XCTestCase {
    @MainActor private func fixture(count: Int = 5, start: Int = 0, sameNames: Bool = false) throws -> PlaylistFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disk = try LocalStorage(root: root)
        var records: [DownloadRecord] = []
        for index in 0..<count {
            let name = sameNames ? "same.mp4" : "video-\(index).mp4"
            let video = Video(name: name, size: 4, contentType: "video/mp4", url: "/api/stream/\(name)",
                              downloadUrl: "/api/download/\(name)")
            var record = DownloadRecord(video: video, server: try ServerAddress.normalize("http://127.0.0.1:\(8100 + index)"))
            record.state = .complete
            try Data([1, 2, 3, 4]).write(to: disk.destination(for: record))
            records.append(record)
        }
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.playLocal(records[start])
        let anchor = try XCTUnwrap(store.playback)
        let pool = PlaylistEnginePool()
        let model = PlaylistPlaybackModel(request: anchor, store: store, engineFactory: { pool.make() },
                                          defaults: defaults, manageAudioSession: false)
        addTeardownBlock { @MainActor in
            model.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return PlaylistFixture(disk: disk, records: records, defaults: defaults, store: store,
                               anchor: anchor, model: model, pool: pool)
    }

    @MainActor func testAllLocalVideosAvailableWithoutServerOrCatalog() throws {
        let f = try fixture(start: 2)
        XCTAssertTrue(f.store.server.isEmpty)
        XCTAssertTrue(f.store.videos.isEmpty)
        XCTAssertFalse(f.store.loading)
        XCTAssertEqual(f.model.entries.map(\.id), f.records.map(\.id))
        XCTAssertEqual(f.model.positionLabel, "3 / 5")
        XCTAssertEqual(f.model.current.key, f.records[2].id)
    }
    @MainActor func testPreviousAndNextSwitchLocalFiles() throws {
        let f = try fixture(start: 2)
        XCTAssertTrue(f.model.move(.previous))
        XCTAssertEqual(f.model.current.key, f.records[1].id)
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.model.current.key, f.records[2].id)
        XCTAssertTrue(f.model.current.url.isFileURL)
    }
    @MainActor func testBoundaryDoesNotStopOrRecreatePlayer() throws {
        let f = try fixture(count: 1)
        let player = f.model.player
        XCTAssertFalse(f.model.move(.previous))
        XCTAssertFalse(f.model.move(.next))
        XCTAssertTrue(f.model.player === player)
        XCTAssertEqual(f.pool.engines.count, 1)
        XCTAssertEqual(f.pool.engines[0].stopCount, 0)
        XCTAssertNotNil(f.model.notice)
    }
    @MainActor func testStopAndSaveHappenBeforeNewEngineIsCreated() throws {
        let f = try fixture()
        f.model.player.attach(to: UIView())
        f.pool.engines[0].tick(12)
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.pool.engines[0].stopCount, 1)
        XCTAssertEqual(f.defaults.double(forKey: "position." + f.records[0].id), 12)
        XCTAssertEqual(f.pool.previousWasStoppedBeforeCreation, [true])
        XCTAssertEqual(f.pool.engines[1].playCount, 0) // Starts only after drawable mounting.
    }
    @MainActor func testMissingNextFileIsSkipped() throws {
        let f = try fixture()
        try f.disk.remove(f.records[1])
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.model.current.key, f.records[2].id)
    }
    @MainActor func testInvalidLocalPayloadIsSkipped() throws {
        let f = try fixture()
        try Data("{bad".utf8).write(to: f.disk.destination(for: f.records[1]))
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.model.current.key, f.records[2].id)
    }
    @MainActor func testNoValidNeighborKeepsCurrentEngineRunning() throws {
        let f = try fixture(count: 2)
        try Data("{bad".utf8).write(to: f.disk.destination(for: f.records[1]))
        XCTAssertFalse(f.model.move(.next))
        XCTAssertEqual(f.model.current.id, f.anchor.id)
        XCTAssertEqual(f.pool.engines[0].stopCount, 0)
    }
    @MainActor func testExplicitInvalidSelectionKeepsCurrentVideo() throws {
        let f = try fixture()
        try f.disk.remove(f.records[2])
        XCTAssertFalse(f.model.select(f.records[2].id))
        XCTAssertFalse(f.model.select("unknown-id"))
        XCTAssertEqual(f.pool.engines[0].stopCount, 0)
        XCTAssertEqual(f.model.current.id, f.anchor.id)
    }
    @MainActor func testSelectingCurrentVideoDoesNotRestart() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.select(f.records[0].id))
        XCTAssertEqual(f.pool.engines.count, 1)
        XCTAssertEqual(f.model.current.id, f.anchor.id)
    }
    @MainActor func testPresentationAnchorStaysButDeletionLeaseMoves() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.store.playback?.id, f.anchor.id)
        f.store.removeFromDevice(f.records[0])
        XCTAssertNil(f.disk.verifiedFile(for: f.records[0]))
        f.store.removeFromDevice(f.records[1])
        XCTAssertNotNil(f.disk.verifiedFile(for: f.records[1]))
        XCTAssertNotNil(f.store.errorMessage)
    }
    @MainActor func testOldCloseCallbackCannotReleaseNewVideo() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.move(.next))
        f.store.playbackDidClose(f.anchor)
        XCTAssertNotNil(f.store.playback)
        f.store.removeFromDevice(f.records[1])
        XCTAssertNotNil(f.disk.verifiedFile(for: f.records[1]))
    }
    @MainActor func testLeaseSurvivesPresentationBindingBeingClearedEarly() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.move(.next))
        f.store.playback = nil
        f.store.removeFromDevice(f.records[1])
        XCTAssertNotNil(f.disk.verifiedFile(for: f.records[1]))
        f.model.close()
        f.store.removeFromDevice(f.records[1])
        XCTAssertNil(f.disk.verifiedFile(for: f.records[1]))
    }
    @MainActor func testFIFODeletesOldCoverAnchorAndPlaylistSkipsIt() throws {
        let f = try fixture()
        for index in 0..<4 {
            if index > 0 { XCTAssertTrue(f.model.move(.next)) }
            XCTAssertTrue(f.store.markForDeletion(f.model.current.key))
        }
        XCTAssertNil(f.disk.verifiedFile(for: f.records[0]))
        XCTAssertEqual(f.store.pendingDeletionRecords.map(\.id), Array(f.records[1...3]).map(\.id))
        XCTAssertEqual(f.model.entries.map(\.id), Array(f.records[1...4]).map(\.id))
        XCTAssertEqual(f.model.positionLabel, "3 / 4")
        XCTAssertTrue(f.model.move(.previous))
        XCTAssertEqual(f.model.current.key, f.records[2].id)
    }
    @MainActor func testEachVideoRestoresOwnBookmark() throws {
        let f = try fixture()
        f.defaults.set(40.0, forKey: "position." + f.records[1].id)
        f.model.player.attach(to: UIView())
        f.pool.engines[0].tick(17)
        XCTAssertTrue(f.model.move(.next))
        f.model.player.attach(to: UIView())
        f.pool.engines[1].tick(0)
        XCTAssertEqual(f.pool.engines[1].seeks, [40])
        XCTAssertEqual(f.defaults.double(forKey: "position." + f.records[0].id), 17)
        XCTAssertEqual(f.model.player.seconds, 40)
    }
    @MainActor func testRapidSwipesAndLateDrawableMountCannotStartOldEngines() throws {
        let f = try fixture()
        let first = f.model.player
        let late = f.pool.engines[0].onUpdate
        XCTAssertTrue(f.model.move(.next))
        let second = f.model.player
        XCTAssertTrue(f.model.move(.next))
        first.attach(to: UIView())
        second.attach(to: UIView())
        late?(PlaybackSnapshot(phase: .playing, seconds: 99, duration: 100, seekable: true))
        XCTAssertTrue(f.pool.engines[0].loaded.isEmpty)
        XCTAssertTrue(f.pool.engines[1].loaded.isEmpty)
        XCTAssertEqual(f.model.player.seconds, 0)
        XCTAssertEqual(f.pool.previousWasStoppedBeforeCreation, [true, true])
    }
    @MainActor func testCloseIsIdempotentAndAllowsReopeningLibrary() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.move(.next))
        f.model.close()
        f.model.close()
        XCTAssertNil(f.store.playback)
        XCTAssertEqual(f.pool.engines.last?.stopCount, 1)
        XCTAssertFalse(f.model.move(.next))
        f.store.playLocal(f.records[3])
        let reopened = try XCTUnwrap(f.store.playback)
        XCTAssertEqual(reopened.key, f.records[3].id)
        f.store.playbackDidClose(reopened)
    }
    @MainActor func testSameFilenameOnDifferentServersRemainsDistinct() throws {
        let f = try fixture(count: 2, sameNames: true)
        XCTAssertEqual(f.model.entries.count, 2)
        XCTAssertNotEqual(f.records[0].id, f.records[1].id)
        XCTAssertTrue(f.model.move(.next))
        XCTAssertEqual(f.model.current.key, f.records[1].id)
    }
    @MainActor func testWrongSessionAndWrongPathRejectedBeforeStopping() throws {
        let f = try fixture()
        let next = try f.store.localPlaybackRequest(for: f.records[1].id)
        var stops = 0
        XCTAssertThrowsError(try f.store.transitionPlayback(from: next, to: f.anchor) { stops += 1 })
        let mismatch = try PlaybackRequest(key: next.key, title: next.title, url: f.anchor.url)
        XCTAssertThrowsError(try f.store.transitionPlayback(from: f.anchor, to: mismatch) { stops += 1 })
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(f.store.playback?.id, f.anchor.id)
    }
    @MainActor func testManualListSelectionAndLateOldCloseDoNotDismissSession() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.select(f.records[4].id))
        XCTAssertEqual(f.model.positionLabel, "5 / 5")
        f.store.playbackDidClose(f.anchor)
        XCTAssertNotNil(f.store.playback)
        XCTAssertTrue(f.model.move(.previous))
        XCTAssertEqual(f.model.current.key, f.records[3].id)
    }
}
