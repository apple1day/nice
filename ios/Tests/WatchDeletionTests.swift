import XCTest
import UIKit
@testable import NiceVideos

final class WatchDeletionTests: XCTestCase {
    @MainActor private func fixture(count: Int = 5) throws -> (LocalStorage, UserDefaults, [DownloadRecord], VideoStore) {
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
    private func staging(_ disk: LocalStorage, _ record: DownloadRecord) -> URL {
        disk.root.appendingPathComponent("RemovalStaging").appendingPathComponent(record.fileName)
    }
    private func stage(_ disk: LocalStorage, _ record: DownloadRecord) throws {
        let target = staging(disk, record)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: disk.destination(for: record), to: target)
    }
    @MainActor private func ids(_ store: VideoStore) -> [String] { store.pendingDeletionRecords.map(\.id) }

    @MainActor func testFirstThreeMarksKeepEveryFileAndCurrentPlayback() throws {
        let (disk, _, entries, store) = try fixture()
        store.playLocal(entries[0])
        let requestID = store.playback?.id
        for record in entries.prefix(3) { XCTAssertTrue(store.markForDeletion(record.id)) }
        XCTAssertEqual(ids(store), entries.prefix(3).map(\.id))
        XCTAssertEqual(store.playback?.id, requestID)
        XCTAssertEqual(store.completed.count, 5)
        for record in entries { XCTAssertNotNil(disk.verifiedFile(for: record)) }
    }
    @MainActor func testFourthMarkDeletesOldestButKeepsCurrentVideoAndThreeNewest() throws {
        let (disk, defaults, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        store.playLocal(entries[3])
        let requestID = store.playback?.id
        XCTAssertTrue(store.markForDeletion(entries[3].id))
        XCTAssertEqual(ids(store), Array(entries[1...3]).map(\.id))
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
        XCTAssertNil(defaults.object(forKey: "position." + entries[0].id))
        XCTAssertEqual(store.playback?.id, requestID)
        XCTAssertNotNil(disk.verifiedFile(for: entries[3]))
        XCTAssertNotNil(disk.verifiedFile(for: entries[4])) // Unmarked video untouched.
        XCTAssertFalse(try disk.loadRecords().contains { $0.id == entries[0].id })
    }
    @MainActor func testRepeatedMarksAreIdempotentWithoutReordering() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        for _ in 0..<20 { XCTAssertTrue(store.markForDeletion(entries[0].id)) }
        XCTAssertEqual(ids(store), entries.prefix(3).map(\.id))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        store.markForDeletion(entries[3].id)
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
    }
    @MainActor func testManyMarksNeverExceedLimitAndPreserveFIFO() throws {
        let (disk, _, entries, store) = try fixture(count: 20)
        for (index, record) in entries.enumerated() {
            XCTAssertTrue(store.markForDeletion(record.id))
            XCTAssertLessThanOrEqual(ids(store).count, 3)
            XCTAssertEqual(ids(store), Array(entries.prefix(index + 1).suffix(3)).map(\.id))
        }
        for record in entries.dropLast(3) { XCTAssertNil(disk.verifiedFile(for: record)) }
        for record in entries.suffix(3) { XCTAssertNotNil(disk.verifiedFile(for: record)) }
    }
    @MainActor func testQueuePersistsAcrossColdStartWithoutServer() throws {
        let (disk, defaults, entries, store) = try fixture()
        for record in entries.prefix(4) { store.markForDeletion(record.id) }
        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(ids(relaunched), Array(entries[1...3]).map(\.id))
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertFalse(relaunched.loading)
        XCTAssertTrue(relaunched.videos.isEmpty)
        relaunched.playLocal(entries[1])
        XCTAssertTrue(try XCTUnwrap(relaunched.playback).url.isFileURL)
    }
    @MainActor func testOldV1ManifestWithoutQueueFieldsStillLoads() throws {
        let (disk, _, entries, _) = try fixture()
        let data = try Data(contentsOf: disk.root.appendingPathComponent("downloads.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("pendingDeletionOrder"))
        let loaded = try disk.loadRecords()
        XCTAssertEqual(loaded, entries)
        XCTAssertTrue(loaded.allSatisfy { $0.pendingDeletionOrder == nil })
        XCTAssertEqual(try JSONDecoder().decode(DownloadManifest.self, from: data).version, 1)
    }
    @MainActor func testUndoKeepsFileAndRemarkGoesToEnd() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        XCTAssertTrue(store.unmarkForDeletion(entries[0].id))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertEqual(ids(store), Array(entries[1...2]).map(\.id))
        XCTAssertTrue(store.markForDeletion(entries[0].id))
        XCTAssertEqual(ids(store), [entries[1].id, entries[2].id, entries[0].id])
        store.markForDeletion(entries[3].id)
        XCTAssertNil(disk.verifiedFile(for: entries[1]))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
    }
    @MainActor func testBulkDeleteOnlyAffectsMarkedFilesAndBookmarks() throws {
        let (disk, defaults, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        XCTAssertEqual(store.deleteAllPendingVideos(), 3)
        XCTAssertTrue(ids(store).isEmpty)
        XCTAssertEqual(store.records.map(\.id), Array(entries.suffix(2)).map(\.id))
        for record in entries.prefix(3) {
            XCTAssertNil(disk.verifiedFile(for: record))
            XCTAssertNil(defaults.object(forKey: "position." + record.id))
        }
        for record in entries.suffix(2) {
            XCTAssertNotNil(disk.verifiedFile(for: record))
            XCTAssertEqual(defaults.double(forKey: "position." + record.id), 12)
        }
        XCTAssertEqual(store.deleteAllPendingVideos(), 0)
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }
    @MainActor func testBulkConfirmationDoesNotExpandToNewMarksOrUnmarkedIDs() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        let confirmed = ids(store) + [entries[4].id]
        store.markForDeletion(entries[1].id)
        XCTAssertEqual(store.deleteAllPendingVideos(ids: confirmed), 1)
        XCTAssertEqual(ids(store), [entries[1].id])
        XCTAssertNotNil(disk.verifiedFile(for: entries[4]))
    }
    @MainActor func testManualDeleteRemovesQueueMembership() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        store.removeFromDevice(entries[0]) // Stale UI snapshot has the same attempt.
        XCTAssertTrue(ids(store).isEmpty)
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
    }
    @MainActor func testUnknownOrMissingFileCannotBeQueued() throws {
        let (disk, _, entries, store) = try fixture()
        XCTAssertFalse(store.markForDeletion("unknown"))
        try disk.remove(entries[0])
        XCTAssertFalse(store.markForDeletion(entries[0].id))
        XCTAssertTrue(ids(store).isEmpty)
    }
    @MainActor func testIncompleteDownloadCannotBeQueued() throws {
        let (disk, defaults, entries, _) = try fixture()
        var downloading = entries[0]
        downloading.state = .downloading
        try Data([0, 1]).write(to: disk.destination(for: downloading))
        try disk.saveRecords([downloading])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertFalse(store.markForDeletion(downloading.id))
        XCTAssertTrue(ids(store).isEmpty)
    }
    @MainActor func testMissingQueuedFileCanBePurgedWithoutNetwork() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        try disk.remove(entries[0])
        store.reconcileFiles()
        XCTAssertEqual(store.deleteAllPendingVideos(), 1)
        XCTAssertTrue(ids(store).isEmpty)
        XCTAssertFalse(store.loading)
    }
    @MainActor func testEvictionFailureRejectsFourthAndPreservesOriginalQueue() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        let original = try Data(contentsOf: disk.root.appendingPathComponent("downloads.json"))
        try disk.remove(entries[0])
        try FileManager.default.createDirectory(at: disk.destination(for: entries[0]), withIntermediateDirectories: true)
        XCTAssertFalse(store.markForDeletion(entries[3].id))
        XCTAssertEqual(ids(store), entries.prefix(3).map(\.id))
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("downloads.json")), original)
        XCTAssertNotNil(disk.verifiedFile(for: entries[3]))
        XCTAssertNotNil(store.errorMessage)
    }
    @MainActor func testFailedIndexWriteRollsBackEvictedVideoAndQueue() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        let originalBytes = try Data(contentsOf: disk.destination(for: entries[0]))
        let index = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data([1]).write(to: index.appendingPathComponent("block-atomic-replace"))
        XCTAssertFalse(store.markForDeletion(entries[3].id))
        XCTAssertEqual(ids(store), entries.prefix(3).map(\.id))
        XCTAssertEqual(try Data(contentsOf: disk.destination(for: entries[0])), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testFailedInitialMarkDoesNotPublishUnpersistedQueue() throws {
        let (disk, _, entries, store) = try fixture()
        let index = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data([1]).write(to: index.appendingPathComponent("block-atomic-replace"))
        XCTAssertFalse(store.markForDeletion(entries[0].id))
        XCTAssertTrue(ids(store).isEmpty)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
    }
    @MainActor func testPartialBulkFailureKeepsFailedItemQueued() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        try disk.remove(entries[1])
        try FileManager.default.createDirectory(at: disk.destination(for: entries[1]), withIntermediateDirectories: true)
        XCTAssertEqual(store.deleteAllPendingVideos(), 2)
        XCTAssertEqual(ids(store), [entries[1].id])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(disk.verifiedFile(for: entries[4]))
    }
    @MainActor func testActiveOldestIsNotUnlinkedAndDoesNotAdmitFourth() throws {
        let (disk, _, entries, store) = try fixture()
        for record in entries.prefix(3) { store.markForDeletion(record.id) }
        store.playLocal(entries[0])
        XCTAssertFalse(store.markForDeletion(entries[3].id))
        XCTAssertEqual(ids(store), entries.prefix(3).map(\.id))
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertEqual(store.playback?.key, entries[0].id)
    }
    @MainActor func testCoverDismissalDoesNotReleaseFileBeforePlayerCloses() throws {
        let (disk, _, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        store.playLocal(entries[0])
        let request = try XCTUnwrap(store.playback)
        store.playback = nil // SwiftUI can clear the binding before onDisappear.
        XCTAssertEqual(store.deleteAllPendingVideos(), 0)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        store.playbackDidClose(request)
        XCTAssertEqual(store.deleteAllPendingVideos(), 1)
    }
    @MainActor func testLateCloseCannotReleaseNewPlaybackLease() throws {
        let (_, _, entries, store) = try fixture()
        store.playLocal(entries[0])
        let old = try XCTUnwrap(store.playback)
        store.playbackDidClose(old)
        store.playLocal(entries[1])
        store.markForDeletion(entries[1].id)
        store.playbackDidClose(old)
        XCTAssertEqual(store.playback?.key, entries[1].id)
        XCTAssertEqual(store.deleteAllPendingVideos(), 0)
    }
    @MainActor func testPlayerStopsBeforeDeletionAndCannotRecreateBookmark() throws {
        let (_, defaults, entries, store) = try fixture()
        store.playLocal(entries[0])
        let request = try XCTUnwrap(store.playback)
        let engine = DeletionTestEngine()
        let model = PlaybackModel(request: request, engine: engine, defaults: defaults, manageAudioSession: false)
        model.attach(to: UIView())
        engine.onUpdate?(PlaybackSnapshot(phase: .playing, seconds: 20, duration: 100, seekable: true))
        store.markForDeletion(entries[0].id)
        XCTAssertEqual(store.deleteAllPendingVideos(), 0)
        model.close()
        XCTAssertEqual(engine.stops, 1)
        store.playbackDidClose(request)
        XCTAssertEqual(store.deleteAllPendingVideos(), 1)
        model.close()
        XCTAssertNil(defaults.object(forKey: "position." + entries[0].id))
    }
    @MainActor func testCrashBeforeCommitRestoresStagedVideoAndOriginalQueue() throws {
        let (disk, defaults, entries, store) = try fixture()
        store.markForDeletion(entries[0].id)
        try stage(disk, entries[0])
        let restarted = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(ids(restarted), [entries[0].id])
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testCrashAfterCommitFinishesDeletionWithoutResurrectingRecord() throws {
        let (disk, defaults, entries, _) = try fixture()
        try stage(disk, entries[0])
        try disk.saveRecords(Array(entries.dropFirst()))
        let restarted = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        XCTAssertFalse(restarted.records.contains { $0.id == entries[0].id })
        XCTAssertNil(defaults.object(forKey: "position." + entries[0].id))
        XCTAssertNil(disk.verifiedFile(for: entries[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testCorruptIndexDoesNotPurgeStagedVideo() throws {
        let (disk, defaults, entries, _) = try fixture()
        try stage(disk, entries[0])
        try Data("{invalid".utf8).write(to: disk.root.appendingPathComponent("downloads.json"))
        let restarted = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        XCTAssertNotNil(restarted.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testMissingIndexDoesNotAuthorizeDeletingStagedVideo() throws {
        let (disk, _, entries, _) = try fixture()
        try stage(disk, entries[0])
        try FileManager.default.removeItem(at: disk.root.appendingPathComponent("downloads.json"))
        XCTAssertThrowsError(try disk.recoverRemovals(records: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testMissingIndexStartupDoesNotOverwriteRecoveryState() throws {
        let (disk, defaults, entries, _) = try fixture()
        try stage(disk, entries[0])
        let manifest = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: manifest)
        let restarted = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        restarted.reconcileFiles()
        restarted.removeFromDevice(entries[0])
        XCTAssertNotNil(restarted.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging(disk, entries[0]).path))
    }
    @MainActor func testSameFilenameOnDifferentServersUsesIndependentQueueEntries() throws {
        let (disk, defaults, entries, _) = try fixture()
        var other = DownloadRecord(video: entries[0].video, server: try ServerAddress.normalize("http://127.0.0.2:9"))
        other.state = .complete
        try Data([0, 1, 2, 3]).write(to: disk.destination(for: other))
        try disk.saveRecords(entries + [other])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.markForDeletion(other.id)
        XCTAssertEqual(store.deleteAllPendingVideos(), 1)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertNil(disk.verifiedFile(for: other))
        XCTAssertFalse(store.loading)
    }
}

private final class DeletionTestEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var stops = 0
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func stop() { stops += 1 }
}
