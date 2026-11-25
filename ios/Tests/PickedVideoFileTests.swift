import Darwin
import UIKit
import XCTest
@testable import NiceVideos

final class PickedVideoFileTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func read(_ file: PickedVideoFile, count: Int = 1, at offset: UInt64) throws -> (Int, [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: count)
        let n = try bytes.withUnsafeMutableBytes { try file.read(into: $0.baseAddress!, count: count, at: offset) }
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
        XCTAssertEqual(try read(source, count: 8, at: tail).1, [0x12, 0x34, 0x56])
        XCTAssertEqual(try read(source, count: 4, at: 0).1, [0x1a, 0x45, 0xdf, 0xa3])
        XCTAssertEqual(try read(source, at: source.byteCount).0, 0)
        XCTAssertEqual(try read(source, at: UInt64.max).0, 0, "A seek beyond EOF yields zero bytes")
    }

    func testAbandonedSelectionReleasesGrantWithoutOpeningFile() throws {
        // There is deliberately no file. Selecting only holds the grant while
        // the sheet dismisses; cancelling during that interval performs no I/O.
        let url = try makeFolder().appendingPathComponent("never-opened.mp4")
        var calls: [String] = []
        var pending: PickedVideoFile.Selection? = .init(url, startAccess: { selected in
            XCTAssertEqual(selected, url)
            calls.append("start")
            return true
        }, endAccess: { released in
            XCTAssertEqual(released, url)
            calls.append("stop")
        })
        XCTAssertEqual(calls, ["start"])
        XCTAssertEqual(pending?.url, url)
        pending = nil
        XCTAssertEqual(calls, ["start", "stop"])
    }

    func testSecurityScopeRemainsUntilFinalOwnerReleasesAndOriginalIsUnchanged() async throws {
        let url = try makeFolder().appendingPathComponent("fixture.mp4")
        let data = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70])
        try data.write(to: url)
        let stopped = expectation(description: "Original URL released once after final owner")
        stopped.assertForOverFulfill = true
        var pending: PickedVideoFile.Selection? = .init(url, startAccess: { $0 == url },
                                                       endAccess: { released in
            XCTAssertEqual(released, url)
            stopped.fulfill()
        })
        weak var originalGrant = pending
        var opened: PickedVideoFile? = try await PickedVideoFile.open(XCTUnwrap(pending))
        pending = nil
        var decoder = opened
        opened = nil
        XCTAssertNotNil(originalGrant, "The decoder must keep the picker's original grant")
        XCTAssertEqual(try read(XCTUnwrap(decoder), at: 4).1, [0x66])
        decoder = nil
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testProviderMetadataChangeDoesNotInvalidateHealthyBytes() async throws {
        let url = try makeFolder().appendingPathComponent("metadata.mp4")
        try Data([1, 2, 3, 4]).write(to: url)
        let source = try await PickedVideoFile.open(url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(try read(source, count: 3, at: 1).1, [2, 3, 4])
    }

    func testSameNameReplacementDoesNotChangeAlreadyOpenedMovie() async throws {
        let url = try makeFolder().appendingPathComponent("same-name.mov")
        try Data([1, 2, 3, 4]).write(to: url)
        let original = try await PickedVideoFile.open(url)
        try Data([9, 8, 7, 6]).write(to: url, options: .atomic)
        XCTAssertEqual(try read(original, count: 4, at: 0).1, [1, 2, 3, 4])
        let replacement = try await PickedVideoFile.open(url)
        XCTAssertEqual(try read(replacement, count: 4, at: 0).1, [9, 8, 7, 6])
    }

    func testTruncationOfOriginalDescriptorReportsIncompleteFile() async throws {
        let url = try makeFolder().appendingPathComponent("truncated.mov")
        try Data([1, 2, 3, 4]).write(to: url)
        let file = try await PickedVideoFile.open(url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 1)
        try writer.close()
        XCTAssertThrowsError(try read(file, at: 0)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, CocoaError.Code.fileReadCorruptFile.rawValue)
        }
    }

    @MainActor
    func testPresenterTracksMovesAndRelinquishesRegistrationWhileBackgrounded() async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("before.mp4")
        let moved = folder.appendingPathComponent("after.mp4")
        try Data([1, 2, 3, 4]).write(to: url)
        var source: PickedVideoFile? = try await PickedVideoFile.open(url)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == url })
        func registered() -> Bool { NSFileCoordinator.filePresenters.contains { $0 === presenter } }
        let center = NotificationCenter.default
        center.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        XCTAssertFalse(registered())
        center.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        XCTAssertTrue(registered())

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var move: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: moved, options: .forReplacing, error: &error) { from, to in
            move = Result {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let error { throw error }
        try XCTUnwrap(move).get()
        let deadline = ContinuousClock.now + .seconds(5)
        while presenter.presentedItemURL?.lastPathComponent != moved.lastPathComponent,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(presenter.presentedItemURL?.lastPathComponent, moved.lastPathComponent)
        XCTAssertEqual(try read(XCTUnwrap(source), count: 4, at: 0).1, [1, 2, 3, 4])
        source = nil
        XCTAssertFalse(registered())
    }

    func testRejectsDisguisedPlaylistsAndBalancesSuccessfulScopeOnFailure() async throws {
        let url = try makeFolder().appendingPathComponent("playlist.mp4")
        try Data("#EXTM3U\nhttps://example.invalid/stream".utf8).write(to: url)
        let stopped = expectation(description: "Scope released after header validation error")
        stopped.assertForOverFulfill = true
        do {
            let selection = PickedVideoFile.Selection(url, startAccess: { _ in true }, endAccess: { released in
                XCTAssertEqual(released, url)
                stopped.fulfill()
            })
            _ = try await PickedVideoFile.open(selection)
            XCTFail("A renamed playlist was accepted")
        } catch OfflineMediaPolicy.Failure.playlist {}
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testAlreadyReadableFileDoesNotStopAnUnacquiredScope() async throws {
        let url = try makeFolder().appendingPathComponent("local.avi")
        try Data([1, 2, 3]).write(to: url)
        var file: PickedVideoFile? = try await PickedVideoFile.open(.init(url, startAccess: { _ in false },
                                                                        endAccess: { _ in XCTFail("unbalanced stop") }))
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
            try await PickedVideoFile.open(.init(url, startAccess: { _ in started.fulfill(); return true },
                                                endAccess: { _ in ended.fulfill() }))
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

    func testCancelledPreparationReleasesSelectionWithoutOpeningFile() async throws {
        let url = try makeFolder().appendingPathComponent("some.mkv")
        let stopped = expectation(description: "Pre-acquired scope released")
        let task = Task {
            let selection = PickedVideoFile.Selection(url, startAccess: { _ in true },
                                                     endAccess: { _ in stopped.fulfill() })
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PickedVideoFile.open(selection)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled file request succeeded")
        } catch is CancellationError {}
        await fulfillment(of: [stopped], timeout: 5)
    }
}
