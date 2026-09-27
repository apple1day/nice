import XCTest
import UIKit
import Combine
@testable import NiceVideos

private final class DeleteButtonEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var stops = 0
    var loads = 0
    var seeks: [Double] = []
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws { loads += 1 }
    func play() {}
    func pause() {}
    func seek(to seconds: Double) { seeks.append(seconds) }
    func stop() { stops += 1 }
}
private final class DeleteButtonProbe {
    var verified: [String] = []
    var engines: [DeleteButtonEngine] = []
    func engine() -> LocalPlaybackEngine {
        let result = DeleteButtonEngine()
        engines.append(result)
        return result
    }
}
private struct DeleteButtonFixture {
    let disk: LocalStorage
    let store: VideoStore
    let model: PlaylistPlaybackModel
    let records: [DownloadRecord]
    let probe: DeleteButtonProbe
}

final class PlayerDeletionInteractionTests: XCTestCase {
    @MainActor private func fixture(count: Int = 3) throws -> DeleteButtonFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let probe = DeleteButtonProbe()
        let disk = try LocalStorage(root: root, onVerify: { probe.verified.append($0) })
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        var records: [DownloadRecord] = []
        for index in 0..<count {
            let video = Video(name: "button-\(index).mp4", size: 4, contentType: "video/mp4",
                              url: "/api/stream/unused", downloadUrl: "/api/download/unused")
            var record = DownloadRecord(video: video, server: server)
            record.state = .complete
            record.downloadedAt = Date(timeIntervalSince1970: 10_000 - Double(index))
            record.favorite = index == 0
            record.watched = false
            try Data([0, 1, 2, 3]).write(to: disk.destination(for: record))
            records.append(record)
        }
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.playLocal(records[0])
        let request = try XCTUnwrap(store.playback)
        let model = PlaylistPlaybackModel(request: request, store: store, engineFactory: { probe.engine() },
                                          defaults: defaults, manageAudioSession: false)
        probe.verified.removeAll()
        addTeardownBlock { @MainActor in
            model.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return DeleteButtonFixture(disk: disk, store: store, model: model, records: records, probe: probe)
    }

    @MainActor func testAfterSeekMarkOnlyValidatesCurrentFileAndKeepsPlayer() throws {
        let f = try fixture(count: 300)
        let player = f.model.player
        player.attach(to: UIView())
        let engine = try XCTUnwrap(f.probe.engines.first)
        engine.onUpdate?(PlaybackSnapshot(phase: .playing, seconds: 12, duration: 100,
                                          seekable: true, hasVideo: false))
        player.seek(to: 60)
        XCTAssertTrue(f.probe.verified.isEmpty)
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertEqual(f.probe.verified, [f.records[0].id])
        XCTAssertEqual(f.store.pendingDeletionRecords.map(\.id), [f.records[0].id])
        XCTAssertNotNil(f.model.currentEntry?.pendingDeletionOrder)
        XCTAssertTrue(f.model.currentEntry?.isFavorite == true)
        XCTAssertEqual(f.model.currentEntry?.downloadedAt, f.records[0].downloadedAt)
        XCTAssertTrue(f.model.player === player)
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(engine.seeks.last, 60)
        XCTAssertTrue(f.model.notice?.contains("已加入待删除") == true)
        XCTAssertEqual(try f.disk.loadRecords(), f.store.records)
    }

    @MainActor func testRepeatedTapsAcknowledgeWithoutRewritesChecksOrUndo() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        let before = f.store.records
        var updates = 0
        let subscription = f.store.$records.dropFirst().sink { _ in updates += 1 }
        f.probe.verified.removeAll()
        for _ in 0..<100 {
            XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        }
        XCTAssertTrue(f.probe.verified.isEmpty)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(f.store.records, before)
        XCTAssertEqual(f.store.pendingDeletionRecords.count, 1)
        XCTAssertTrue(f.model.notice?.contains("已在待删除列表") == true)
        XCTAssertNotNil(f.disk.verifiedFile(for: f.records[0]))
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testStalePressCannotMarkTheNextVideo() throws {
        let f = try fixture()
        let oldRequest = f.model.current.id
        XCTAssertTrue(f.model.move(.next))
        f.probe.verified.removeAll()
        XCTAssertFalse(f.model.markCurrentForDeletion(expectedRequestID: oldRequest))
        XCTAssertTrue(f.store.pendingDeletionRecords.isEmpty)
        XCTAssertTrue(f.probe.verified.isEmpty)
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertEqual(f.store.pendingDeletionRecords.map(\.id), [f.records[1].id])
    }

    @MainActor func testClosedOrDismissingPlayerReportsInsteadOfMarking() throws {
        let f = try fixture()
        let request = f.model.current.id
        f.store.playback = nil
        XCTAssertFalse(f.model.markCurrentForDeletion(expectedRequestID: request))
        f.model.close()
        XCTAssertFalse(f.model.markCurrentForDeletion(expectedRequestID: request))
        XCTAssertTrue(f.store.pendingDeletionRecords.isEmpty)
        XCTAssertNotNil(f.model.notice)
        XCTAssertTrue(f.probe.verified.isEmpty)
    }

    @MainActor func testFailedSaveDoesNotPublishSuccessAndCanRetry() throws {
        let f = try fixture()
        let path = f.disk.root.appendingPathComponent("downloads.json")
        let original = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data([1]).write(to: path.appendingPathComponent("block-atomic-replace"))
        XCTAssertFalse(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertNil(f.model.currentEntry?.pendingDeletionOrder)
        XCTAssertTrue(f.store.pendingDeletionRecords.isEmpty)
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertTrue(f.model.notice?.contains("未加入待删除") == true)
        XCTAssertNotNil(f.disk.verifiedFile(for: f.records[0]))
        try FileManager.default.removeItem(at: path)
        try original.write(to: path)
        f.store.errorMessage = nil
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertNotNil(f.model.currentEntry?.pendingDeletionOrder)
    }

    @MainActor func testMissingCurrentFileReportsFailureWithoutStoppingPlayback() throws {
        let f = try fixture()
        try f.disk.remove(f.records[0])
        XCTAssertFalse(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertNil(f.model.currentEntry?.pendingDeletionOrder)
        XCTAssertEqual(f.probe.engines[0].stops, 0)
    }

    @MainActor func testDecoderFailureDoesNotDisableMarkingExistingLocalFile() throws {
        let f = try fixture()
        f.model.player.attach(to: UIView())
        f.probe.engines[0].onUpdate?(PlaybackSnapshot(phase: .failed, seconds: 0, duration: 0, seekable: false))
        XCTAssertEqual(f.model.player.phase, .failed)
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertEqual(f.store.pendingDeletionRecords.count, 1)
        XCTAssertEqual(f.probe.engines[0].stops, 0)
    }

    @MainActor func testMarkingNeverDeletesAndActiveFileStillProtected() throws {
        let f = try fixture(count: 5)
        for _ in 0..<4 {
            XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
            XCTAssertTrue(f.model.move(.next))
        }
        XCTAssertTrue(f.model.markCurrentForDeletion(expectedRequestID: f.model.current.id))
        XCTAssertEqual(f.store.pendingDeletionRecords.count, 5)
        for record in f.records { XCTAssertNotNil(f.disk.verifiedFile(for: record)) }
        XCTAssertEqual(f.store.deleteAllPendingVideos(ids: [f.model.current.key]), 0)
        f.model.close()
        XCTAssertEqual(f.store.deleteAllPendingVideos(), 5)
        XCTAssertTrue(f.store.records.isEmpty)
    }
}
