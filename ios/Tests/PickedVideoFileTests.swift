import Darwin
import XCTest
@testable import NiceVideos

final class PickedVideoFileTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func read(_ file: PickedVideoFile, count: Int = 1, at offset: UInt64) -> (Int, [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: count)
        let n = bytes.withUnsafeMutableBytes { file.read(into: $0.baseAddress!, count: count, at: offset) }
        return (n, Array(bytes.prefix(max(0, n))))
    }

    func testSparseFileOver4GiBSupportsIndependent64BitReadsWithoutImporting() async throws {
        let directory = try makeFolder()
        let url = directory.appendingPathComponent("眺望 #1%.mkv")
        try Data([0x1a, 0x45, 0xdf, 0xa3]).write(to: url)
        // Sparse: cross both signed and unsigned 32-bit limits without allocating 4 GiB.
        let tail = UInt64(UInt32.max) + 19
        let writer = try FileHandle(forWritingTo: url)
        try writer.seek(toOffset: tail)
        try writer.write(contentsOf: Data([0x12, 0x34, 0x56]))
        try writer.close()

        let source = try await PickedVideoFile.open(url)
        XCTAssertEqual(source.byteCount, tail + 3)
        XCTAssertEqual(source.url.lastPathComponent, url.lastPathComponent)
        XCTAssertEqual(read(source, count: 8, at: tail).1, [0x12, 0x34, 0x56])
        XCTAssertEqual(read(source, count: 4, at: 0).1, [0x1a, 0x45, 0xdf, 0xa3])
        XCTAssertEqual(read(source, at: source.byteCount).0, 0)
        XCTAssertEqual(read(source, at: UInt64.max).0, -1)
    }

    func testSecurityScopeRemainsUntilFinalOwnerReleasesAndOriginalIsUnchanged() async throws {
        let url = try makeFolder().appendingPathComponent("fixture.mp4")
        let data = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70])
        try data.write(to: url)
        let stopped = expectation(description: "Original URL released once after final owner")
        stopped.assertForOverFulfill = true
        var opened: PickedVideoFile? = try await PickedVideoFile.open(
            url, startAccess: { $0 == url }, endAccess: { released in
                XCTAssertEqual(released, url)
                stopped.fulfill()
            })
        var decoder = opened
        opened = nil
        XCTAssertEqual(read(try XCTUnwrap(decoder), at: 4).1, [0x66])
        decoder = nil
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testRejectsReplacementOrTruncationBetweenReads() async throws {
        let url = try makeFolder().appendingPathComponent("same-name.mov")
        try Data([1, 2, 3, 4]).write(to: url)
        let original = try await PickedVideoFile.open(url)
        try Data([9, 8, 7, 6]).write(to: url, options: .atomic)
        XCTAssertEqual(read(original, at: 0).0, -1, "Do not switch to a replacement file mid-movie")

        let replacement = try await PickedVideoFile.open(url)
        XCTAssertEqual(read(replacement, at: 0).1, [9])
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 1)
        try writer.close()
        XCTAssertEqual(read(replacement, at: 0).0, -1, "Do not read invalidated offsets")
    }

    func testRejectsDisguisedPlaylistsAndBalancesSuccessfulScopeOnFailure() async throws {
        let url = try makeFolder().appendingPathComponent("playlist.mp4")
        try Data("#EXTM3U\nhttps://example.invalid/stream".utf8).write(to: url)
        let stopped = expectation(description: "Scope released after header validation error")
        stopped.assertForOverFulfill = true
        do {
            _ = try await PickedVideoFile.open(url, startAccess: { _ in true }, endAccess: { released in
                XCTAssertEqual(released, url)
                stopped.fulfill()
            })
            XCTFail("A renamed playlist was accepted")
        } catch OfflineMediaPolicy.Failure.playlist {}
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testAlreadyReadableFileDoesNotStopAnUnacquiredScope() async throws {
        let url = try makeFolder().appendingPathComponent("local.avi")
        try Data([1, 2, 3]).write(to: url)
        var file: PickedVideoFile? = try await PickedVideoFile.open(url, startAccess: { _ in false },
                                                                   endAccess: { _ in XCTFail("unbalanced stop") })
        XCTAssertEqual(file?.byteCount, 3)
        file = nil
    }

    func testCancelWhileWaitingForProviderBalancesScope() async throws {
        let url = try makeFolder().appendingPathComponent("busy.mp4")
        try Data([0, 1, 2, 3]).write(to: url)
        let writing = expectation(description: "Independent coordinator holds write access")
        let releaseWriter = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                writing.fulfill()
                _ = releaseWriter.wait(timeout: .now() + 10)
            }
        }
        await fulfillment(of: [writing], timeout: 5)
        let started = expectation(description: "Security scope acquired")
        let ended = expectation(description: "Security scope balanced on cancellation")
        let task = Task {
            try await PickedVideoFile.open(url, startAccess: { _ in started.fulfill(); return true },
                                           endAccess: { _ in ended.fulfill() })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        releaseWriter.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled file request succeeded")
        } catch is CancellationError {}
        await fulfillment(of: [ended], timeout: 5)
    }

    func testCancellationBeforeOpeningNeverStartsScope() async throws {
        let url = try makeFolder().appendingPathComponent("some.mkv")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PickedVideoFile.open(url, startAccess: { _ in XCTFail("opened after cancel"); return true },
                                                 endAccess: { _ in XCTFail("unexpected stop") })
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled file request succeeded")
        } catch is CancellationError {}
    }
}
