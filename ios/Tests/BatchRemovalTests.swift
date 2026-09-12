import XCTest
@testable import NiceVideos

final class BatchRemovalTests: XCTestCase {
    @MainActor private func fixture(_ states: [DownloadState]) throws -> (LocalStorage, UserDefaults, [DownloadRecord], VideoStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "batch-removal-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let disk = try LocalStorage(root: root)
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        let records = try states.enumerated().map { index, state -> DownloadRecord in
            let video = Video(name: "视频 \(index)+%#.mp4", size: 4, contentType: "video/mp4",
                              url: "/api/stream/unused", downloadUrl: "/api/download/unused")
            var record = DownloadRecord(video: video, server: server)
            record.state = state
            try Data(state == .complete ? [0, 1, 2, 3] : [0, 1]).write(to: disk.destination(for: record))
            defaults.set(12.0, forKey: "position." + record.id)
            return record
        }
        try disk.saveRecords(records)
        return (disk, defaults, records, VideoStore(storage: disk, defaults: defaults, restoreDownloads: false))
    }

    @MainActor func testLocalBatchOnlyDeletesSelectedFilesBookmarksAndQueueEntries() throws {
        let (disk, defaults, records, store) = try fixture([.complete, .complete, .complete])
        XCTAssertTrue(store.markForDeletion(records[0].id))
        let result = store.removeBatch(BatchRemovalRequest(scope: .localVideos, records: [records[0], records[2]]))
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(store.records.map(\.id), [records[1].id])
        XCTAssertTrue(store.pendingDeletionRecords.isEmpty)
        for record in [records[0], records[2]] {
            XCTAssertNil(disk.verifiedFile(for: record))
            XCTAssertNil(defaults.object(forKey: "position." + record.id))
        }
        XCTAssertNotNil(disk.verifiedFile(for: records[1]))
        XCTAssertEqual(defaults.double(forKey: "position." + records[1].id), 12)
        XCTAssertEqual(try disk.loadRecords(), store.records)
        let reopened = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(reopened.records, store.records)
        XCTAssertTrue(reopened.videos.isEmpty)
        XCTAssertFalse(reopened.loading) // No server fetch was needed for the batch.
    }

    @MainActor func testEmptyAndDuplicateSelectionAreSafe() throws {
        let (_, _, records, store) = try fixture([.complete, .complete])
        XCTAssertEqual(store.removeBatch(BatchRemovalRequest(scope: .localVideos, records: [])).removedCount, 0)
        let request = BatchRemovalRequest(scope: .localVideos, records: [records[0], records[0]])
        XCTAssertEqual(request.records.count, 1)
        XCTAssertEqual(store.removeBatch(request).removedCount, 1)
        XCTAssertEqual(store.removeBatch(request).skippedCount, 1)
        XCTAssertEqual(store.records, [records[1]])
    }

    @MainActor func testTaskMultiDeleteRemovesPartialFilesButKeepsCompletedAndUnselectedTasks() throws {
        let (disk, _, records, store) = try fixture([.downloading, .failed, .complete, .downloading])
        let result = store.removeBatch(BatchRemovalRequest(scope: .downloadTasks, records: Array(records.prefix(2))))
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(store.records, Array(records.suffix(2)))
        for record in records.prefix(2) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try disk.destination(for: record).path))
        }
        XCTAssertNotNil(disk.verifiedFile(for: records[2]))
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }

    @MainActor func testClearAllAlwaysExcludesCompletedEvenIfCallerPassesEveryRecord() throws {
        let (disk, defaults, records, store) = try fixture([.failed, .complete, .downloading, .failed])
        let request = BatchRemovalRequest(scope: .downloadTasks, records: records, clearAll: true)
        XCTAssertEqual(request.records.count, 3)
        XCTAssertEqual(store.removeBatch(request).removedCount, 3)
        XCTAssertTrue(store.unfinished.isEmpty)
        XCTAssertEqual(store.completed, [records[1]])
        XCTAssertNotNil(disk.verifiedFile(for: records[1]))
        XCTAssertEqual(defaults.double(forKey: "position." + records[1].id), 12)
        XCTAssertEqual(try disk.loadRecords(), [records[1]])
    }

    @MainActor func testTaskCompletedWhileConfirmationIsOpenIsPreserved() throws {
        let (disk, _, records, store) = try fixture([.downloading, .failed])
        let request = BatchRemovalRequest(scope: .downloadTasks, records: store.unfinished, clearAll: true)
        try Data([0, 1, 2, 3]).write(to: disk.destination(for: records[0]))
        store.reconcileFiles()
        let result = store.removeBatch(request)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(store.completed.map(\.id), [records[0].id])
        XCTAssertNotNil(disk.verifiedFile(for: records[0]))
    }

    @MainActor func testCompleteFileWithStaleDownloadStateIsNotRemoved() throws {
        let (disk, _, records, store) = try fixture([.downloading])
        let request = BatchRemovalRequest(scope: .downloadTasks, records: records, clearAll: true)
        try Data([0, 1, 2, 3]).write(to: disk.destination(for: records[0]))
        let result = store.removeBatch(request) // Before any reconciliation callback.
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertNotNil(disk.verifiedFile(for: records[0]))
    }

    @MainActor func testOldDialogCannotDeleteRetriedTaskWithSameFileID() throws {
        let (disk, defaults, records, _) = try fixture([.failed])
        let request = BatchRemovalRequest(scope: .downloadTasks, records: records)
        var retried = records[0]
        retried.attempt = UUID().uuidString
        retried.state = .downloading
        try disk.saveRecords([retried])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(store.removeBatch(request).skippedCount, 1)
        XCTAssertEqual(store.records, [retried])
        XCTAssertEqual(try disk.loadRecords(), [retried])
    }

    @MainActor func testClearSnapshotDoesNotIncludeTasksAddedLater() throws {
        let (disk, defaults, records, store) = try fixture([.failed, .downloading])
        let request = BatchRemovalRequest(scope: .downloadTasks, records: [records[0]], clearAll: true)
        XCTAssertEqual(store.removeBatch(request).removedCount, 1)
        XCTAssertEqual(store.records, [records[1]])
        XCTAssertEqual(VideoStore(storage: disk, defaults: defaults, restoreDownloads: false).records, [records[1]])
    }

    @MainActor func testLocalScopeCannotDeleteAnUnfinishedRecord() throws {
        let (_, _, records, store) = try fixture([.complete, .downloading])
        let request = BatchRemovalRequest(scope: .localVideos, records: records)
        XCTAssertEqual(request.records.count, 1)
        XCTAssertEqual(store.removeBatch(request).removedCount, 1)
        XCTAssertEqual(store.records, [records[1]])
    }

    @MainActor func testPlayingFileIsProtectedAndOtherSelectedFilesStillDelete() throws {
        let (disk, _, records, store) = try fixture([.complete, .complete])
        store.playLocal(records[0])
        let request = try XCTUnwrap(store.playback)
        let result = store.removeBatch(BatchRemovalRequest(scope: .localVideos, records: records))
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(store.playback?.id, request.id)
        XCTAssertNotNil(disk.verifiedFile(for: records[0]))
        XCTAssertNil(disk.verifiedFile(for: records[1]))
        XCTAssertNotNil(store.errorMessage)
        store.playbackDidClose(request)
    }

    @MainActor func testIndexWriteFailureRestoresFilesAndKeepsBookmarksAndRecords() throws {
        let (disk, defaults, records, store) = try fixture([.complete, .complete])
        let manifest = disk.root.appendingPathComponent("downloads.json")
        let original = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: manifest)
            try? original.write(to: manifest)
        }
        let result = store.removeBatch(BatchRemovalRequest(scope: .localVideos, records: records))
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(store.records, records)
        for record in records {
            XCTAssertNotNil(disk.verifiedFile(for: record))
            XCTAssertEqual(defaults.double(forKey: "position." + record.id), 12)
        }
    }

    @MainActor func testLateDownloadCallbacksCannotResurrectDeletedTask() throws {
        let (disk, _, records, store) = try fixture([.downloading])
        let record = records[0]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Suspended task: delegate callbacks are injected without network traffic.
        let task = session.downloadTask(with: URL(string: "http://127.0.0.1:9/unused")!)
        task.taskDescription = record.taskToken
        store.urlSession(session, downloadTask: task, didWriteData: 2, totalBytesWritten: 2, totalBytesExpectedToWrite: 4)
        XCTAssertNotNil(store.progress[record.id])
        XCTAssertEqual(store.removeBatch(BatchRemovalRequest(scope: .downloadTasks, records: records)).removedCount, 1)
        XCTAssertNil(store.progress[record.id])
        let temp = disk.root.appendingPathComponent("late-download")
        try Data([0, 1, 2, 3]).write(to: temp)
        store.urlSession(session, downloadTask: task, didFinishDownloadingTo: temp)
        store.urlSession(session, downloadTask: task, didWriteData: 2, totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
        store.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.progress.isEmpty)
        XCTAssertTrue(try disk.loadRecords().isEmpty)
        XCTAssertNil(disk.verifiedFile(for: record))
    }

    func testSelectionRequiresExplicitModeAndEndsWithoutDeletingAnything() {
        var selection = BatchSelection()
        selection.toggle("a")
        XCTAssertTrue(selection.tokens.isEmpty)
        selection.begin()
        selection.toggle("a")
        selection.toggle("b")
        XCTAssertEqual(selection.tokens, ["a", "b"])
        selection.end()
        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.tokens.isEmpty)
    }

    func testSelectAllOnlyUsesVisibleRowsAndSearchPrunesHiddenSelections() {
        var selection = BatchSelection()
        selection.begin()
        selection.toggleAll(in: ["a", "b"])
        XCTAssertTrue(selection.allSelected(in: ["a", "b"]))
        selection.reconcile(with: ["b", "c"])
        XCTAssertEqual(selection.tokens, ["b"])
        XCTAssertFalse(selection.allSelected(in: ["b", "c"]))
        selection.toggleAll(in: ["b", "c"])
        XCTAssertEqual(selection.tokens, ["b", "c"])
        selection.toggleAll(in: ["b", "c"])
        XCTAssertTrue(selection.tokens.isEmpty)
    }

    func testCompletionOrRetryRemovesSelectionWithoutSelectingNewTask() {
        var selection = BatchSelection()
        selection.begin()
        selection.toggleAll(in: ["file|old", "other|attempt"])
        selection.reconcile(with: ["file|new", "new-file|attempt"])
        XCTAssertTrue(selection.tokens.isEmpty)
        XCTAssertFalse(selection.allSelected(in: []))
    }
}
