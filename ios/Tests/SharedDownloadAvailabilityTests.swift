import XCTest
@testable import NiceVideos

final class SharedDownloadAvailabilityTests: XCTestCase {
    private func fixture(_ states: [DownloadState]) throws -> (LocalStorage, UserDefaults, [DownloadRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = try LocalStorage(root: root)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        var records: [DownloadRecord] = []
        for (i, state) in states.enumerated() {
            let video = Video(name: "clip-\(i).mp4", size: 4, contentType: "video/mp4",
                              url: "/api/stream/unused", downloadUrl: "/api/download/unused")
            var record = DownloadRecord(video: video, server: server)
            record.publicFileName = try disk.availableFileName(for: record, among: records)
            record.state = state
            records.append(record)
        }
        return (disk, defaults, records)
    }

    @MainActor func testMovedFileKeepsHistoryAndBecomesPlayableWhenPutBack() async throws {
        let (disk, defaults, records) = try fixture([.complete])
        var record = records[0]
        record.downloadedAt = Date(timeIntervalSince1970: 1234)
        record.favorite = true
        record.watched = true
        record.pendingDeletionOrder = 0
        defaults.set(29.5, forKey: "position." + record.id)
        let original = try disk.destination(for: record)
        try Data([1, 2, 3, 4]).write(to: original)
        try disk.saveRecords([record])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let moved = original.deletingLastPathComponent().appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: original, to: moved)
        await store.refreshDownloadedFiles()
        let missing = try XCTUnwrap(store.records.first)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missing.taskToken, record.taskToken)
        XCTAssertEqual(missing.downloadedAt, record.downloadedAt)
        XCTAssertTrue(missing.hasWatched && missing.isFavorite)
        XCTAssertEqual(defaults.double(forKey: "position." + record.id), 29.5)
        XCTAssertNil(missing.pendingDeletionOrder)
        XCTAssertTrue(store.completed.isEmpty && store.unfinished.isEmpty)
        XCTAssertTrue(store.localPlaylistRecords.isEmpty)
        XCTAssertEqual(store.usedBytes, 0)
        XCTAssertEqual(try disk.loadRecords().first?.state, .missing)
        XCTAssertThrowsError(try store.localPlaybackRequest(for: record.id))
        let reopened = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        try FileManager.default.moveItem(at: moved, to: original)
        await reopened.refreshDownloadedFiles()
        XCTAssertEqual(reopened.records.first?.taskToken, record.taskToken)
        XCTAssertEqual(reopened.completed.first?.downloadedAt, record.downloadedAt)
        XCTAssertEqual(reopened.usedBytes, 4)
        XCTAssertEqual(try reopened.localPlaybackRequest(for: record.id).url, original)
    }

    @MainActor func testExternalChangesDoNotBecomeOrdinaryFailedOrActiveDownloads() async throws {
        let (disk, defaults, fixtureRecords) = try fixture([.complete, .failed, .downloading])
        let untouched = Array(fixtureRecords.dropFirst())
        let mismatch = try disk.destination(for: fixtureRecords[0])
        try Data([0]).write(to: mismatch)
        try disk.saveRecords(fixtureRecords)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        await store.refreshDownloadedFiles()
        XCTAssertEqual(store.records[0].state, .failed)
        XCTAssertEqual(Array(store.records.dropFirst()), untouched)
        XCTAssertEqual(try Data(contentsOf: mismatch), Data([0]))
        try Data([1, 2, 3, 4]).write(to: mismatch)
        await store.refreshDownloadedFiles()
        XCTAssertEqual(store.records[0].state, .complete)
        XCTAssertEqual(Array(store.records.dropFirst()), untouched)
    }

    @MainActor func testFailedRedownloadRetainsDeletedHistoryAfterRelaunch() async throws {
        let (disk, defaults, records) = try fixture([.downloading])
        var retry = records[0]
        retry.retryingMissingDownload = true
        retry.downloadedAt = Date(timeIntervalSince1970: 100)
        retry.favorite = true
        try disk.saveRecords([retry])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let task = URLSession.shared.downloadTask(with: URL(fileURLWithPath: "/unused"))
        task.taskDescription = retry.taskToken
        store.urlSession(.shared, task: task, didCompleteWithError: URLError(.notConnectedToInternet))
        XCTAssertEqual(store.records[0].state, .missing)
        XCTAssertNil(store.records[0].retryingMissingDownload)
        XCTAssertFalse(store.records[0].message?.isEmpty ?? true)
        XCTAssertTrue(store.unfinished.isEmpty)
        let reopened = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        await reopened.refreshDownloadedFiles()
        XCTAssertEqual(reopened.records, store.records)
        XCTAssertTrue(reopened.records[0].isFavorite)
        XCTAssertEqual(reopened.records[0].downloadedAt, retry.downloadedAt)
    }

    @MainActor func testOnlyHistoricalMissingFailureIsReclassifiedAsDeleted() throws {
        let (disk, defaults, fixtureRecords) = try fixture([.failed, .failed])
        var records = fixtureRecords
        records[0].message = "本地文件缺失或大小异常，请重新下载。"
        records[1].message = "下载超时"
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(store.records.map(\.state), [.missing, .failed])
        XCTAssertEqual(store.unfinished.map(\.id), [records[1].id])
        XCTAssertNil(store.records[0].downloadedAt)
    }

    @MainActor func testRetryRestoredFileReconcilesWithoutStartingNetworkTask() throws {
        let (disk, defaults, records) = try fixture([.missing])
        let record = records[0]
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        try Data([1, 2, 3, 4]).write(to: disk.destination(for: record))
        store.retry(record)
        XCTAssertEqual(store.records.first?.state, .complete)
        XCTAssertEqual(store.records.first?.attempt, record.attempt)
        XCTAssertNil(store.progress[record.id])
        XCTAssertNil(store.errorMessage)
    }
}
