import XCTest
@testable import NiceVideos

@MainActor final class PickedUploadDocumentTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testSelectsLargeFileWithoutReadingItsBytesAndDeduplicatesSelection() async throws {
        let file = try directory().appendingPathComponent("全景 8K.MP4")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        let size: UInt64 = 3 * 1024 * 1024 * 1024 + 37
        try handle.truncate(atOffset: size)
        try handle.close()
        let sources = try await LocalUploadSource.pickedFiles([file, file])
        XCTAssertEqual(sources.map(\.name), ["全景 8K.MP4"])
        XCTAssertEqual(sources.map(\.size), [Int64(size)])
        XCTAssertNotNil(sources.first?.pickedFile)
    }

    func testUnsupportedOrEmptySelectionDoesNotReturnPartialBatch() async throws {
        let dir = try directory()
        let valid = dir.appendingPathComponent("ok.mov")
        try Data([1]).write(to: valid)
        for (name, bytes) in [("playlist.m3u8", Data([1])), ("empty.mp4", Data())] {
            let bad = dir.appendingPathComponent(name)
            try bytes.write(to: bad)
            do {
                _ = try await LocalUploadSource.pickedFiles([valid, bad])
                XCTFail("An invalid item should keep this batch out of the queue")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(name))
            }
        }
    }

    func testRetryResolvesSavedBookmarkAndStagedBytesSurviveEditsToOriginal() async throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("VR + 眼镜.mp4")
        let initial = Data([1, 4, 2, 8])
        try initial.write(to: url)
        let picked = try await LocalUploadSource.pickedFiles([url])
        let source = try XCTUnwrap(picked.first)
        let disk = try LocalUploadDisk(root: dir.appendingPathComponent("private"))
        var job = LocalUploadJob(source: source, server: URL(string: "https://example.test")!, allowsCellular: false)
        job.state = .uploading
        try disk.save([job])
        let manager = LocalUploadManager(root: disk.root, resolveSource: { _ in
            XCTFail("Relaunch must not resend the selected movie")
            throw CancellationError()
        })
        let restored = try XCTUnwrap(manager.jobs.first)
        XCTAssertEqual(restored.state, .failed)
        let document = try XCTUnwrap(restored.source.pickedFile)
        let copy = try await document.prepare(restored.source, destination: disk.stagedFile(job.id))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([8, 2, 4, 1]))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: copy), initial)
        try disk.removeSnapshot(job.id)
        XCTAssertEqual(try Data(contentsOf: url), Data([8, 2, 4, 1]))
    }

    func testChangedOrReplacedSelectionCannotSilentlyUploadOtherBytes() async throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("clip.mp4")
        try Data([1, 2]).write(to: url)
        let picked = try await LocalUploadSource.pickedFiles([url])
        let source = try XCTUnwrap(picked.first)
        let document = try XCTUnwrap(source.pickedFile)
        // Replace with a different inode at the original path and identical length.
        let replacement = dir.appendingPathComponent("replacement")
        try Data([4, 3]).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        let staging = dir.appendingPathComponent("stage")
        do {
            _ = try await document.prepare(source, destination: staging)
            XCTFail("A replacement movie was accepted")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            XCTAssertEqual(try Data(contentsOf: url), Data([4, 3]))
        }
    }

    func testCancelBeforeDocumentPreparationNeverStartsTransferAndKeepsPickedFile() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("original.mp4")
        try Data([1, 2, 3]).write(to: file)
        let selected = try await LocalUploadSource.pickedFiles([file])
        let disk = try LocalUploadDisk(root: dir.appendingPathComponent("queue"))
        let manager = LocalUploadManager(root: disk.root, resolveSource: { _ in
            XCTFail("External file should not be resolved as a library record")
            throw CancellationError()
        })
        defer { manager.invalidate() }
        XCTAssertTrue(manager.enqueue(selected, server: URL(string: "http://127.0.0.1:9")!, allowsCellular: false))
        let id = try XCTUnwrap(manager.jobs.first?.id)
        // Prepare runs asynchronously; both calls occur in the same main actor turn.
        manager.cancel(id)
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        for _ in 0..<100 {
            manager.clearFinished()
            if manager.jobs.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.stagedFile(id).path))
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
}
