import XCTest
@testable import NiceVideos

final class BatchDeletionTests: XCTestCase {
    @MainActor private func fixture(_ states: [DownloadState]) throws
        -> (LocalStorage, UserDefaults, [DownloadRecord], VideoStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "batch-delete-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let disk = try LocalStorage(root: root)
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        var entries: [DownloadRecord] = []
        for (index, state) in states.enumerated() {
            let video = Video(name: "批量 \(index)+%#.mp4", size: 4, contentType: "video/mp4",
                              url: "/api/stream/unused", downloadUrl: "/api/download/unused")
            var entry = DownloadRecord(video: video, server: server)
            entry.state = state
            if state == .complete {
                try Data([0, 1, 2, 3]).write(to: disk.destination(for: entry))
            } else if state == .downloading {
                try Data([0, 1]).write(to: disk.destination(for: entry))
            }
            defaults.set(20.0, forKey: "position." + entry.id)
            entries.append(entry)
        }
        try disk.saveRecords(entries)
        return (disk, defaults, entries, VideoStore(storage: disk, defaults: defaults, restoreDownloads: false))
    }

    @MainActor func testLocalBatchDeletesOnlySelectedFilesBookmarksAndQueueMembership() throws {
        let (disk, defaults, entries, store) = try fixture([.complete, .complete, .complete, .failed])
        store.markForDeletion(entries[0].id)
        store.markForDeletion(entries[2].id)
        let result = store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: Array(entries.prefix(2))))
        XCTAssertEqual(result.removedTokens, Set(entries.prefix(2).map(\.taskToken)))
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.details.count, 2)
        XCTAssertEqual(store.pendingDeletionRecords.map(\.id), [entries[2].id])
        for entry in entries.prefix(2) {
            XCTAssertNil(disk.verifiedFile(for: entry))
            XCTAssertNil(defaults.object(forKey: "position." + entry.id))
        }
        XCTAssertNotNil(disk.verifiedFile(for: entries[2]))
        XCTAssertEqual(defaults.double(forKey: "position." + entries[2].id), 20)
        XCTAssertEqual(store.records.map(\.id), Array(entries.suffix(2)).map(\.id))
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }

    @MainActor func testClearTasksRemovesUnfinishedAndPartialFilesButKeepsCompleted() throws {
        let (disk, defaults, entries, store) = try fixture([.complete, .downloading, .failed])
        let request = BatchDeletionRequest(scope: .downloadTasks, records: store.records, clearAll: true)
        XCTAssertEqual(request.records.count, 2)
        let result = store.deleteBatch(request)
        XCTAssertEqual(result.removedTokens.count, 2)
        XCTAssertTrue(store.unfinished.isEmpty)
        XCTAssertEqual(store.completed.map(\.id), [entries[0].id])
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try disk.destination(for: entries[1]).path))
        XCTAssertEqual(defaults.double(forKey: "position." + entries[0].id), 20)
        XCTAssertNil(defaults.object(forKey: "position." + entries[1].id))
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }

    @MainActor func testNewlyCompletedTaskIsNotDeletedByOldConfirmation() throws {
        let (disk, _, entries, store) = try fixture([.downloading, .failed])
        let request = BatchDeletionRequest(scope: .downloadTasks, records: store.unfinished, clearAll: true)
        try Data([0, 1, 2, 3]).write(to: disk.destination(for: entries[0]))
        store.reconcileFiles() // Completion while the confirmation dialog is open.
        let result = store.deleteBatch(request)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.removedTokens, [entries[1].taskToken])
        XCTAssertEqual(store.completed.map(\.id), [entries[0].id])
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
    }

    @MainActor func testClearSnapshotNeverExpandsToUnconfirmedJobs() throws {
        let (_, _, entries, store) = try fixture([.failed, .downloading, .failed])
        let request = BatchDeletionRequest(scope: .downloadTasks, records: [entries[0]], clearAll: true)
        store.deleteBatch(request)
        XCTAssertEqual(store.records.map(\.id), Array(entries.suffix(2)).map(\.id))
    }

    @MainActor func testRetryAttemptCannotBeDeletedByOldConfirmation() throws {
        let (disk, defaults, entries, _) = try fixture([.failed])
        let request = BatchDeletionRequest(scope: .downloadTasks, records: entries)
        let retry = DownloadRecord(video: entries[0].video, server: try ServerAddress.normalize(entries[0].server))
        XCTAssertEqual(retry.id, entries[0].id)
        XCTAssertNotEqual(retry.taskToken, entries[0].taskToken)
        try disk.saveRecords([retry])
        let current = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let result = current.deleteBatch(request)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.removedTokens.isEmpty)
        XCTAssertEqual(current.records, [retry])
    }

    @MainActor func testOffScopeAndDuplicateSnapshotsAreExcluded() throws {
        let (_, _, entries, _) = try fixture([.complete, .downloading])
        let local = BatchDeletionRequest(scope: .localVideos, records: entries + entries)
        let tasks = BatchDeletionRequest(scope: .downloadTasks, records: entries + entries)
        XCTAssertEqual(local.records, [entries[0]])
        XCTAssertEqual(tasks.records, [entries[1]])
    }

    @MainActor func testEmptySelectionIsNoOpAndRepeatedConfirmationDoesNotDeleteAnythingElse() throws {
        let (disk, _, entries, store) = try fixture([.complete, .complete])
        let empty = store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: []))
        XCTAssertTrue(empty.removedTokens.isEmpty)
        XCTAssertEqual(store.records, entries)
        let request = BatchDeletionRequest(scope: .localVideos, records: [entries[0]])
        store.deleteBatch(request)
        let again = store.deleteBatch(request)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertTrue(again.removedTokens.isEmpty)
        XCTAssertNotNil(disk.verifiedFile(for: entries[1]))
    }

    @MainActor func testPartialFailureRetainsFailedRowAndContinuesWithOtherRows() throws {
        let (disk, _, entries, store) = try fixture([.complete, .complete, .complete])
        try disk.remove(entries[1])
        try FileManager.default.createDirectory(at: disk.destination(for: entries[1]), withIntermediateDirectories: true)
        let result = store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: entries))
        XCTAssertEqual(result.removedTokens, [entries[0].taskToken, entries[2].taskToken])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(store.records, [entries[1]])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try disk.loadRecords(), store.records)
    }

    @MainActor func testManifestWriteFailureRollsBackFilesAndKeepsBookmarks() throws {
        let (disk, defaults, entries, store) = try fixture([.complete, .complete])
        let manifest = disk.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data([1]).write(to: manifest.appendingPathComponent("prevent-atomic-replace"))
        let result = store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: entries))
        XCTAssertTrue(result.removedTokens.isEmpty)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(store.records, entries)
        for entry in entries {
            XCTAssertNotNil(disk.verifiedFile(for: entry))
            XCTAssertEqual(defaults.double(forKey: "position." + entry.id), 20)
        }
    }

    @MainActor func testPlayingVideoRemainsProtectedDuringBatchRemoval() throws {
        let (disk, _, entries, store) = try fixture([.complete, .complete])
        store.playLocal(entries[0])
        let playbackID = store.playback?.id
        let result = store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: entries))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.removedTokens, [entries[1].taskToken])
        XCTAssertEqual(store.playback?.id, playbackID)
        XCTAssertNotNil(disk.verifiedFile(for: entries[0]))
        XCTAssertEqual(store.records, [entries[0]])
    }

    @MainActor func testDeletedTaskLateCallbacksCannotRestoreRowOrProgress() throws {
        let (disk, _, entries, store) = try fixture([.downloading])
        let record = entries[0]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: try XCTUnwrap(URL(string: "http://127.0.0.1:9/unused")))
        task.taskDescription = record.taskToken
        // Do not resume: simulate callbacks without making any network requests.
        store.urlSession(session, downloadTask: task, didWriteData: 2,
                         totalBytesWritten: 2, totalBytesExpectedToWrite: 4)
        XCTAssertNotNil(store.progress[record.id])
        store.deleteBatch(BatchDeletionRequest(scope: .downloadTasks, records: [record]))
        let temp = disk.root.appendingPathComponent("late-download")
        try Data([0, 1, 2, 3]).write(to: temp)
        store.urlSession(session, downloadTask: task, didFinishDownloadingTo: temp)
        store.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        store.urlSession(session, downloadTask: task, didWriteData: 2,
                         totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.progress[record.id])
        XCTAssertNil(disk.verifiedFile(for: record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertTrue(try disk.loadRecords().isEmpty)
    }

    @MainActor func testBatchRemovalPersistsAcrossOfflineColdStart() throws {
        let (disk, defaults, entries, store) = try fixture([.complete, .complete, .failed])
        store.deleteBatch(BatchDeletionRequest(scope: .localVideos, records: [entries[0]]))
        let relaunched = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(relaunched.records.map(\.id), Array(entries.suffix(2)).map(\.id))
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertFalse(relaunched.loading)
        relaunched.playLocal(entries[1])
        XCTAssertTrue(try XCTUnwrap(relaunched.playback).url.isFileURL)
    }

    func testSelectionOnlyIncludesVisibleRowsAndDoesNotFollowRetries() {
        var selection = BatchSelection()
        selection.begin()
        selection.toggleAll(in: ["one|attempt1", "two|attempt1", "three|attempt1"])
        selection.retainVisible(["two|attempt1", "three|attempt1"])
        XCTAssertEqual(selection.tokens, ["two|attempt1", "three|attempt1"])
        selection.retainVisible(["two|attempt2", "three|attempt1"])
        XCTAssertEqual(selection.tokens, ["three|attempt1"])
        selection.cancel()
        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.tokens.isEmpty)
    }
}
