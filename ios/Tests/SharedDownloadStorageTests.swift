import XCTest
@testable import NiceVideos

final class SharedDownloadStorageTests: XCTestCase {
    private let bytes = Data([0, 1, 2, 3])

    private func store() throws -> LocalStorage {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return try LocalStorage(root: base.appendingPathComponent("Support"),
                                documents: base.appendingPathComponent("Documents"))
    }
    private func record(_ name: String = "原片.mp4", server: String = "one") throws -> DownloadRecord {
        let video = Video(name: name, size: 4, contentType: "video/mp4", url: "", downloadUrl: "/api/download/test")
        return DownloadRecord(video: video, server: try ServerAddress.normalize("https://" + server + ".example"))
    }
    private func legacy(_ entry: DownloadRecord, disk: LocalStorage) throws -> URL {
        let folder = disk.root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(entry.fileName)
    }

    func testV1MigrationMovesBytesWithoutCopyAndReservesNamesAcrossServersAndFiles() throws {
        let disk = try store()
        var first = try record()
        var second = try record(server: "two")
        first.state = .complete
        first.favorite = true
        first.watched = true
        first.pendingDeletionOrder = 1
        first.downloadedAt = Date(timeIntervalSince1970: 1200)
        second.state = .complete
        let userFile = try disk.destination(for: first)
        let other = Data([5, 6, 7, 8])
        try other.write(to: userFile)
        first.publicFileName = nil
        second.publicFileName = nil
        let old = try legacy(first, disk: disk)
        try bytes.write(to: old)
        try bytes.write(to: legacy(second, disk: disk))
        try disk.saveRecords([first, second])
        let inode = try FileManager.default.attributesOfItem(atPath: old.path)[.systemFileNumber] as? NSNumber
        let moved = try disk.migrateLegacyDownloads(disk.loadRecords())
        XCTAssertEqual(moved.map(\.publicFileName), ["原片 (2).mp4", "原片 (3).mp4"])
        XCTAssertEqual(moved[0].taskToken, first.taskToken)
        XCTAssertEqual(moved[0].pendingDeletionOrder, 1)
        XCTAssertTrue(moved[0].isFavorite && moved[0].hasWatched)
        XCTAssertEqual(moved[0].downloadedAt, first.downloadedAt)
        XCTAssertEqual(try Data(contentsOf: userFile), other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let published = try XCTUnwrap(disk.verifiedFile(for: moved[0]))
        XCTAssertEqual(try Data(contentsOf: published), bytes)
        XCTAssertNotNil(inode)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: published.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(try disk.loadRecords(), moved)
        try FileManager.default.removeItem(at: published)
        XCTAssertEqual(try disk.migrateLegacyDownloads(moved), moved)
        XCTAssertEqual(disk.fileStatus(for: moved[0]), .absent)
    }

    func testInterruptedMigrationResumesWithoutReplacingNewlyOccupiedTarget() throws {
        let disk = try store()
        var entry = try record()
        entry.state = .complete
        // The mapping was persisted immediately before the process stopped.
        try disk.saveRecords([entry])
        let original = try legacy(entry, disk: disk)
        try bytes.write(to: original)
        let unexpected = try disk.destination(for: entry)
        try Data([4, 5, 6, 7]).write(to: unexpected)
        let moved = try XCTUnwrap(disk.migrateLegacyDownloads(disk.loadRecords()).first)
        XCTAssertEqual(moved.publicFileName, "原片 (2).mp4")
        XCTAssertEqual(try Data(contentsOf: unexpected), Data([4, 5, 6, 7]))
        XCTAssertEqual(try Data(contentsOf: disk.destination(for: moved)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try disk.migrateLegacyDownloads(disk.loadRecords()), [moved])
    }

    func testMigrationIndexFailureLeavesOnlyPrivateSource() throws {
        let disk = try store()
        var entry = try record()
        let planned = try disk.destination(for: entry)
        entry.publicFileName = nil
        let original = try legacy(entry, disk: disk)
        try bytes.write(to: original)
        try FileManager.default.createDirectory(at: disk.root.appendingPathComponent("downloads.json"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try disk.migrateLegacyDownloads([entry]))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planned.path))
        XCTAssertThrowsError(try disk.loadRecords())
    }

    func testOldStagedRemovalRestoresBeforeMigrationAndPartialRemainsPrivateUntilTaskIsRemoved() throws {
        let disk = try store()
        var complete = try record()
        complete.state = .complete
        complete.publicFileName = nil
        var partial = try record("半部.mp4")
        partial.publicFileName = nil
        let partialFile = try legacy(partial, disk: disk)
        try Data([0, 1]).write(to: partialFile)
        let staged = disk.root.appendingPathComponent("RemovalStaging")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try bytes.write(to: staged.appendingPathComponent(complete.fileName))
        try disk.saveRecords([complete, partial])
        try disk.recoverRemovals(records: [complete, partial])
        let migrated = try disk.migrateLegacyDownloads(disk.loadRecords())
        XCTAssertEqual(try Data(contentsOf: disk.destination(for: migrated[0])), bytes)
        XCTAssertEqual(disk.fileStatus(for: migrated[1]), .absent)
        let userFile = try disk.destination(for: migrated[1])
        let foreign = Data([9, 9, 9, 9]) // Same size still belongs to the user.
        try foreign.write(to: userFile)
        _ = try disk.removeAndSave(migrated[1], records: [migrated[0]])
        XCTAssertEqual(try Data(contentsOf: userFile), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialFile.path))
        XCTAssertEqual(try disk.loadRecords(), [migrated[0]])
    }

    func testForgettingMissingRecordKeepsFileRestoredAfterRefresh() throws {
        let disk = try store()
        var entry = try record()
        entry.state = .missing
        try disk.saveRecords([entry])
        let file = try disk.destination(for: entry)
        try bytes.write(to: file)
        _ = try disk.removeAndSave(entry, records: [])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(try disk.loadRecords().isEmpty)
    }

    func testFilenamesStayInsideDownloadsAndRespectCaseUnicodeAndByteLimit() throws {
        let disk = try store()
        let malicious = try record("../../\\hidden/..:片.mp4")
        let target = try disk.destination(for: malicious)
        XCTAssertEqual(target.deletingLastPathComponent().lastPathComponent, "下载")
        XCTAssertFalse(target.lastPathComponent.contains(":") || target.lastPathComponent.hasPrefix("."))
        let long = try record(String(repeating: "影片", count: 100) + ".mp4")
        XCTAssertLessThanOrEqual(try disk.availableFileName(for: long, among: []).utf8.count, 255)
        let first = try record("Favorité.mp4")
        let second = try record("FAVORITE\u{0301}.mp4", server: "two")
        XCTAssertTrue(try disk.availableFileName(for: second, among: [first]).hasSuffix(" (2).mp4"))
        var corrupt = first
        corrupt.publicFileName = "../secret.mp4"
        XCTAssertThrowsError(try disk.destination(for: corrupt))
    }

    func testCompletionCannotReplaceLateCollisionAndRetriesCanUseNewName() throws {
        let disk = try store()
        var entry = try record()
        let target = try disk.destination(for: entry)
        let foreign = Data([7, 7, 7, 7])
        try foreign.write(to: target)
        let temp = disk.root.appendingPathComponent("temporary-download")
        try bytes.write(to: temp)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(fileURLWithPath: "/local"), statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4"]))
        XCTAssertThrowsError(try disk.finish(temp: temp, response: response, record: entry))
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        entry.publicFileName = try disk.availableFileName(for: entry, among: [entry])
        try disk.finish(temp: temp, response: response, record: entry)
        XCTAssertEqual(try Data(contentsOf: disk.destination(for: entry)), bytes)
        XCTAssertEqual(try Data(contentsOf: target), foreign)
    }
}
