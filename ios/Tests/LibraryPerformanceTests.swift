import XCTest
import UIKit
@testable import NiceVideos

private final class LibraryProbe { var ids: [String] = [] }
private final class LibraryEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func stop() {}
    func emit(_ phase: PlaybackPhase, video: Bool = false) {
        onUpdate?(PlaybackSnapshot(phase: phase, seconds: 1, duration: 100,
                                   seekable: true, hasVideo: video))
    }
}

final class LibraryPerformanceTests: XCTestCase {
    @MainActor private func fixture(count: Int = 3, size: Int64 = 4, writeFiles: Bool = true)
        throws -> (LocalStorage, UserDefaults, [DownloadRecord], VideoStore, LibraryProbe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let probe = LibraryProbe()
        let disk = try LocalStorage(root: root, onVerify: { probe.ids.append($0) })
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        var records: [DownloadRecord] = []
        for index in 0..<count {
            var record = DownloadRecord(video: Video(name: "video-\(index).mp4", size: size,
                contentType: "video/mp4", url: "/api/stream/unused", downloadUrl: "/api/download/unused"), server: server)
            record.state = .complete
            if writeFiles { try Data([1, 2, 3, 4]).write(to: disk.destination(for: record)) }
            records.append(record)
        }
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (disk, defaults, records, store, probe)
    }

    @MainActor func test300Record60GBMetadataListDoesNotOpenMediaFiles() throws {
        // 60 GB is represented in metadata only; this test does not allocate/read 60 GB.
        let (_, _, records, store, probe) = try fixture(count: 300, size: 200_000_000, writeFiles: false)
        let list = LocalLibraryModel(store: store)
        XCTAssertEqual(store.usedBytes, 60_000_000_000)
        XCTAssertEqual(list.visibleRows.count, 300)
        XCTAssertEqual(list.visibleRows.first?.id, records.last?.id)
        for _ in 0..<300 {
            _ = list.visibleRows.map { ($0.subtitle, $0.record.hasWatched, $0.record.isFavorite) }
            _ = list.summary
            _ = store.completed
            _ = store.pendingDeletionRecords
            store.objectWillChange.send()
        }
        XCTAssertEqual(list.metadataBuildCount, 1)
        XCTAssertTrue(probe.ids.isEmpty)
    }

    @MainActor func testSearchUsesMetadataAndKeepsDescendingOrder() throws {
        let (_, _, records, store, probe) = try fixture(count: 30)
        let list = LocalLibraryModel(store: store)
        list.setSearch("video-1")
        XCTAssertEqual(list.visibleRows.map(\.id), Array(records[10...19].reversed()).map(\.id) + [records[1].id])
        list.setSearch("")
        XCTAssertEqual(list.visibleRows.map(\.id), records.reversed().map(\.id))
        XCTAssertEqual(list.metadataBuildCount, 1)
        XCTAssertTrue(probe.ids.isEmpty)
    }

    @MainActor func testCompletionTimestampOrderMatchesPlaylistAndDoesNotChangeOnFavorite() throws {
        let (disk, defaults, records, _, probe) = try fixture()
        var updated = records
        updated[0].downloadedAt = Date(timeIntervalSince1970: 300)
        updated[1].downloadedAt = Date(timeIntervalSince1970: 100)
        updated[2].downloadedAt = Date(timeIntervalSince1970: 200)
        try disk.saveRecords(updated)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let list = LocalLibraryModel(store: store)
        XCTAssertEqual(list.visibleRows.map(\.id), [records[0].id, records[2].id, records[1].id])
        XCTAssertTrue(probe.ids.isEmpty)
        store.playLocal(records[0])
        let request = try XCTUnwrap(store.playback)
        let model = PlaylistPlaybackModel(request: request, store: store,
            engineFactory: { LibraryEngine() }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        XCTAssertEqual(model.entries.map(\.id), list.visibleRows.map(\.id))
        store.toggleFavorite(records[2].id)
        XCTAssertEqual(model.entries.map(\.id), list.visibleRows.map(\.id))
        XCTAssertTrue(list.visibleRows[1].record.isFavorite)
    }

    @MainActor func testOldWatchFlagMigratesOnlyFromPositiveBookmarkWithoutFileChecks() throws {
        let (disk, defaults, records, _, probe) = try fixture()
        var legacy = records
        for index in legacy.indices { legacy[index].watched = nil }
        defaults.set(25.0, forKey: "position." + records[0].id)
        try disk.saveRecords(legacy)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertTrue(store.completed[0].hasWatched)
        XCTAssertFalse(store.completed[1].hasWatched)
        XCTAssertNil(store.completed[0].downloadedAt)
        XCTAssertTrue(try disk.loadRecords()[0].hasWatched)
        XCTAssertTrue(probe.ids.isEmpty)
    }

    @MainActor func testOpenAndFailedPlaybackDoNotMarkWatchedButRealVideoOutputDoes() throws {
        let (disk, defaults, records, store, probe) = try fixture()
        let list = LocalLibraryModel(store: store)
        store.playLocal(records[0])
        let engine = LibraryEngine()
        let model = PlaylistPlaybackModel(request: try XCTUnwrap(store.playback), store: store,
            engineFactory: { engine }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        model.player.attach(to: UIView())
        probe.ids.removeAll()
        engine.emit(.opening)
        engine.emit(.failed)
        engine.emit(.playing, video: false)
        XCTAssertFalse(store.completed[0].hasWatched)
        engine.emit(.playing, video: true)
        XCTAssertTrue(store.completed[0].hasWatched)
        XCTAssertTrue(try disk.loadRecords()[0].hasWatched)
        let buildCount = list.metadataBuildCount
        for _ in 0..<500 { engine.emit(.playing, video: true) }
        XCTAssertEqual(list.metadataBuildCount, buildCount)
        XCTAssertTrue(probe.ids.isEmpty, "Time notifications must not validate media files")
    }

    @MainActor func testPausedLateVideoOutputDoesNotMarkWatched() throws {
        let (_, defaults, records, store, _) = try fixture()
        store.playLocal(records[0])
        let engine = LibraryEngine()
        let model = PlaylistPlaybackModel(request: try XCTUnwrap(store.playback), store: store,
            engineFactory: { engine }, defaults: defaults, manageAudioSession: false)
        model.player.attach(to: UIView())
        model.player.pause()
        engine.emit(.playing, video: true)
        XCTAssertFalse(store.completed[0].hasWatched)
        model.close()
        engine.emit(.playing, video: true)
        XCTAssertFalse(store.completed[0].hasWatched)
    }

    @MainActor func testWatchedSaveFailurePreservesExistingManifestState() throws {
        let (disk, _, records, store, _) = try fixture()
        store.playLocal(records[0])
        let index = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data([1]).write(to: index.appendingPathComponent("block"))
        store.markWatched(records[0].id)
        XCTAssertFalse(store.completed[0].hasWatched)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testPendingToolbarSnapshotIgnoresNewMarksAndUndo() throws {
        let (_, _, records, store, _) = try fixture()
        store.markForDeletion(records[0].id)
        let confirmed = store.pendingDeletionRecords
        store.markForDeletion(records[1].id)
        store.unmarkForDeletion(records[0].id)
        XCTAssertEqual(store.deletePendingVideos(confirmed), 0)
        XCTAssertEqual(store.completed.count, 3)
        XCTAssertEqual(store.pendingDeletionRecords.map(\.id), [records[1].id])
    }

    @MainActor func testPendingToolbarSnapshotCannotDeleteNewDownloadAttempt() throws {
        let (disk, defaults, records, store, _) = try fixture()
        store.markForDeletion(records[0].id)
        let confirmed = store.pendingDeletionRecords
        var replacement = try disk.loadRecords()
        replacement[0].attempt = UUID().uuidString
        try disk.saveRecords(replacement)
        let restarted = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(restarted.deletePendingVideos(confirmed), 0)
        XCTAssertEqual(restarted.completed.count, 3)
    }

    @MainActor func testPendingToolbarDeletesOnlyConfirmedFilesAndUpdatesList() throws {
        let (disk, _, records, store, _) = try fixture()
        let list = LocalLibraryModel(store: store)
        store.markForDeletion(records[0].id)
        store.markForDeletion(records[1].id)
        let confirmed = list.pendingRecords
        XCTAssertEqual(store.deletePendingVideos(confirmed), 2)
        XCTAssertEqual(list.visibleRows.map(\.id), [records[2].id])
        XCTAssertTrue(list.pendingRecords.isEmpty)
        XCTAssertNotNil(disk.verifiedFile(for: records[2]))
    }
}
