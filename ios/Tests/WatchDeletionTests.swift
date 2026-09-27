import XCTest
@testable import NiceVideos

final class WatchDeletionTests: XCTestCase {
    @MainActor private func fixture(count: Int = 8) throws -> (LocalStorage, UserDefaults, [DownloadRecord], VideoStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "watch-delete-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let disk = try LocalStorage(root: root)
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        var entries: [DownloadRecord] = []
        for index in 0..<count {
            let name = "视频 \(index)+%#.mp4"
            let video = Video(name: name, size: 4, contentType: "video/mp4",
                              url: "/api/stream/unused", downloadUrl: "/api/download/unused")
            var entry = DownloadRecord(video: video, server: server)
            entry.state = .complete
            try Data([0, 1, 2, UInt8(index % 256)]).write(to: disk.destination(for: entry))
            defaults.set(12.0, forKey: "position." + entry.id)
            entries.append(entry)
        }
        try disk.saveRecords(entries)
        return (disk, defaults, entries, VideoStore(storage: disk, defaults: defaults, restoreDownloads: false))
    }

    @MainActor private func ids(_ store: VideoStore) -> [String] {
        store.pendingDeletionRecords.map(\.id)
    }

    @MainActor func testMarkingManyVideosHasNoLimitAndNeverDeletesAutomatically() throws {
        let (disk, defaults, entries, store) = try fixture(count: 12)
        for record in entries {
            XCTAssertTrue(store.markForDeletion(record.id))
        }
        XCTAssertEqual(ids(store), entries.map(\.id))
        XCTAssertEqual(store.completed.count, entries.count)
        for record in entries {
            XCTAssertNotNil(disk.verifiedFile(for: record), record.video.name)
            XCTAssertEqual(defaults.double(forKey: "position." + record.id), 12)
        }
        XCTAssertTrue(store.deletionNotice?.contains("删除待删除") == true)
    }

    @MainActor func testRepeatedMarkIsIdempotentAndDoesNotReorder() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(4) { XCTAssertTrue(store.markForDeletion(record.id)) }
        for _ in 0..<20 { XCTAssertTrue(store.markForDeletion(entries[0].id)) }
        XCTAssertEqual(ids(store), Array(entries.prefix(4)).map(\.id))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
    }

    @MainActor func testQueuePersistsAcrossColdStartWithoutServer() throws {
        let (disk, defaults, entries, store) = try fixture(count: 7)
        for record in entries { store.markForDeletion(record.id) }
        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(ids(relaunched), entries.map(\.id))
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertFalse(relaunched.loading)
        for record in entries { XCTAssertNotNil(disk.verifiedFile(for: record)) }
    }

    @MainActor func testUndoKeepsFileAndRemarkMovesToEnd() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(4) { store.markForDeletion(record.id) }
        XCTAssertTrue(store.unmarkForDeletion(entries[0].id))
        XCTAssertEqual(ids(store), Array(entries[1...3]).map(\.id))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertTrue(store.markForDeletion(entries[0].id))
        XCTAssertEqual(ids(store), [entries[1].id, entries[2].id, entries[3].id, entries[0].id])
    }

    @MainActor func testOneClickDeleteRemovesOnlyQueuedFilesAndBookmarks() throws {
        let (disk, defaults, entries, store) = try fixture()
        let marked = [entries[0], entries[2], entries[4], entries[6]]
        for record in marked { store.markForDeletion(record.id) }
        XCTAssertEqual(store.deleteAllPendingVideos(), marked.count)
        XCTAssertTrue(store.pendingDeletionRecords.isEmpty)
        for record in marked {
            XCTAssertNil(disk.verifiedFile(for: record))
            XCTAssertNil(defaults.object(forKey: "position." + record.id))
        }
        for record in entries where !marked.contains(where: { $0.id == record.id }) {
            XCTAssertNotNil(disk.verifiedFile(for: record))
            XCTAssertEqual(defaults.double(forKey: "position." + record.id), 12)
        }
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }

    @MainActor func testConfirmationSnapshotDoesNotExpandToNewMarks() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        store.markForDeletion(entries[1].id)
        let confirmed = ids(store)
        store.markForDeletion(entries[2].id)
        XCTAssertEqual(store.deleteAllPendingVideos(ids: confirmed), 2)
        XCTAssertEqual(ids(store), [entries[2].id])
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
        XCTAssertNil(disk.verifiedFile(for: entries[1]))
        XCTAssertNotNil(disk.verifiedFile(for: entries[2]))
    }

    @MainActor func testPlayingQueuedVideoIsNotDeletedUntilPlayerCloses() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        store.playLocal(entries[0])
        let request = try XCTUnwrap(store.playback)
        XCTAssertEqual(store.deleteAllPendingVideos(), 0)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertEqual(ids(store), [entries[0].id])
        XCTAssertNotNil(store.errorMessage)
        store.errorMessage = nil
        store.playbackDidClose(request)
        XCTAssertEqual(store.deleteAllPendingVideos(), 1)
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
    }

    @MainActor func testUnknownMissingAndIncompleteFilesCannotBeQueued() throws {
        let (disk, defaults, entries, _) = try fixture()
        var incomplete = entries[0]
        incomplete.state = .downloading
        try Data([0, 1]).write(to: disk.destination(for: incomplete))
        try disk.saveRecords([incomplete] + Array(entries.dropFirst()))
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertFalse(store.markForDeletion("unknown"))
        XCTAssertFalse(store.markForDeletion(incomplete.id))
        try disk.remove(entries[1])
        XCTAssertFalse(store.markForDeletion(entries[1].id))
        XCTAssertTrue(store.pendingDeletionRecords.isEmpty)
    }

    @MainActor func testFailedIndexWriteDoesNotPublishPendingMarkOrDeleteFile() throws {
        let (disk, _, entries, store) = try fixture()
        let index = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data([1]).write(to: index.appendingPathComponent("block-atomic-replace"))
        XCTAssertFalse(store.markForDeletion(entries[0].id))
        XCTAssertTrue(store.pendingDeletionRecords.isEmpty)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
    }

    @MainActor func testManualDeleteAlsoRemovesPendingMembership() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        store.removeFromDevice(entries[0])
        XCTAssertFalse(store.isPendingDeletion(entries[0].id))
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
    }
}
