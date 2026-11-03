import XCTest
import UIKit
@testable import NiceVideos

private final class FilterPlaybackEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func stop() {}
}

private final class FilterVerificationProbe {
    var ids: [String] = []
}

final class VideoListFilterTests: XCTestCase {
    @MainActor private func fixture() throws
        -> (VideoStore, [DownloadRecord], UserDefaults, FilterVerificationProbe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let probe = FilterVerificationProbe()
        let disk = try LocalStorage(root: root, onVerify: { probe.ids.append($0) })
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        let names = ["alpha.mp4", "beta.mp4", "alpha-two.mp4", "delta.mp4", "echo.mp4"]
        var records: [DownloadRecord] = []
        for (index, name) in names.enumerated() {
            var record = DownloadRecord(video: Video(name: name, size: 4, contentType: "video/mp4",
                url: "/api/stream/" + name, downloadUrl: "/api/download/" + name), server: server)
            record.state = .complete
            record.downloadedAt = Date(timeIntervalSince1970: Double(names.count - index))
            record.favorite = index.isMultiple(of: 2)
            record.watched = index == 1 || index == 4
            if index == 3 { record.watched = nil }
            try Data([1, 2, 3, 4]).write(to: disk.destination(for: record))
            records.append(record)
        }
        try disk.saveRecords(records)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (store, records, defaults, probe)
    }

    @MainActor func testFavoritesAndSearchIntersectWithoutReorderingOrReadingFiles() throws {
        let (store, records, _, probe) = try fixture()
        let library = LocalLibraryModel(store: store)
        library.setFilter(.favorites)
        XCTAssertEqual(library.visibleRows.map(\.id), [records[0].id, records[2].id, records[4].id])
        library.setSearch("ALPHA")
        XCTAssertEqual(library.visibleRows.map(\.id), [records[0].id, records[2].id])
        XCTAssertEqual(library.visibleTokens, [records[0].taskToken, records[2].taskToken])
        library.setFilter(.all)
        XCTAssertEqual(library.visibleRows.map(\.id), [records[0].id, records[2].id])
        library.setSearch("")
        XCTAssertEqual(library.visibleRows.map(\.id), records.map(\.id))
        XCTAssertEqual(library.metadataBuildCount, 1)
        XCTAssertTrue(probe.ids.isEmpty)
    }

    @MainActor func testUnwatchedIncludesLegacyUnsetFlagAndPrunesBatchSelection() throws {
        let (store, records, _, probe) = try fixture()
        let library = LocalLibraryModel(store: store)
        var selection = BatchSelection()
        selection.begin()
        selection.toggleAll(in: library.visibleTokens)

        library.setFilter(.unwatched)
        selection.retainVisible(library.visibleTokens)

        XCTAssertEqual(library.visibleRows.map(\.id), [records[0].id, records[2].id, records[3].id])
        XCTAssertEqual(selection.tokens, Set([records[0].taskToken, records[2].taskToken, records[3].taskToken]))
        XCTAssertTrue(probe.ids.isEmpty)
        XCTAssertTrue(VideoListFilter.unwatched.matches(nil))
        XCTAssertFalse(VideoListFilter.favorites.matches(nil))
    }

    @MainActor func testUnwatchedQueueSurvivesWatchMarkBeforePlayerModelIsCreated() throws {
        let (store, records, defaults, _) = try fixture()
        let library = LocalLibraryModel(store: store)
        library.setFilter(.unwatched)
        let snapshot = library.visibleRows.map(\.id)
        store.playLocal(records[0], playlistIDs: snapshot)
        let request = try XCTUnwrap(store.playback)

        store.markWatched(records[0].id)
        XCTAssertEqual(library.visibleRows.map(\.id), [records[2].id, records[3].id])
        XCTAssertEqual(request.playlistIDs, snapshot)

        let model = PlaylistPlaybackModel(request: request, store: store,
            engineFactory: { FilterPlaybackEngine() }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        XCTAssertEqual(model.entries.map(\.id), snapshot)
        XCTAssertEqual(model.current.key, records[0].id)
        XCTAssertTrue(model.move(.next))
        XCTAssertEqual(model.current.key, records[2].id)
        store.markWatched(records[2].id)
        XCTAssertEqual(library.visibleRows.map(\.id), [records[3].id])
        XCTAssertEqual(model.entries.map(\.id), snapshot)
        XCTAssertTrue(model.move(.next))
        XCTAssertEqual(model.current.key, records[3].id)
        XCTAssertFalse(model.move(.next))
    }

    @MainActor func testTappedMiddleFavoriteStartsThereAndFavoriteChangesDoNotAlterQueue() throws {
        let (store, records, defaults, _) = try fixture()
        let library = LocalLibraryModel(store: store)
        library.setFilter(.favorites)
        store.playLocal(records[2], playlistIDs: library.visibleRows.map(\.id))
        let request = try XCTUnwrap(store.playback)
        let model = PlaylistPlaybackModel(request: request, store: store,
            engineFactory: { FilterPlaybackEngine() }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        XCTAssertEqual(model.current.key, records[2].id)
        XCTAssertEqual(model.positionLabel, "2 / 3")

        XCTAssertFalse(store.toggleFavorite(records[4].id))
        XCTAssertTrue(store.toggleFavorite(records[1].id))
        library.setSearch("beta")

        XCTAssertEqual(library.visibleRows.map(\.id), [records[1].id])
        XCTAssertEqual(model.entries.map(\.id), [records[0].id, records[2].id, records[4].id])
        XCTAssertTrue(model.move(.next))
        XCTAssertEqual(model.current.key, records[4].id)
        XCTAssertFalse(model.move(.next))
        XCTAssertFalse(model.select(records[1].id))
    }

    @MainActor func testVisibleOrderOverridesDownloadOrderAndOnlyCapturesRequestedItems() throws {
        let (store, records, defaults, probe) = try fixture()
        // A server/search view can have a different display order from local
        // download timestamps. Hidden/unfinished items are not supplied by it.
        let visiblePlayableIDs = [records[3].id, records[0].id, records[2].id]
        store.playLocal(records[0], playlistIDs: visiblePlayableIDs)
        let request = try XCTUnwrap(store.playback)
        XCTAssertEqual(request.playlistIDs, visiblePlayableIDs)
        XCTAssertEqual(probe.ids, [records[0].id], "Opening only validates the selected file")
        let model = PlaylistPlaybackModel(request: request, store: store,
            engineFactory: { FilterPlaybackEngine() }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        XCTAssertEqual(model.entries.map(\.id), visiblePlayableIDs)
        XCTAssertEqual(model.positionLabel, "2 / 3")
        XCTAssertEqual(model.neighbor(.previous)?.id, records[3].id)
        XCTAssertEqual(model.neighbor(.next)?.id, records[2].id)
        XCTAssertFalse(model.select(records[1].id))
    }

    @MainActor func testSingleFilteredItemDoesNotFallBackToTheWholeLibrary() throws {
        let (store, records, defaults, _) = try fixture()
        let library = LocalLibraryModel(store: store)
        library.setSearch("echo")
        store.playLocal(records[4], playlistIDs: library.visibleRows.map(\.id))
        let model = PlaylistPlaybackModel(request: try XCTUnwrap(store.playback), store: store,
            engineFactory: { FilterPlaybackEngine() }, defaults: defaults, manageAudioSession: false)
        defer { model.close() }
        XCTAssertEqual(model.entries.map(\.id), [records[4].id])
        XCTAssertFalse(model.canMove(.previous))
        XCTAssertFalse(model.canMove(.next))
    }
}
