import XCTest
@testable import NiceVideos

final class ServerManagementTests: XCTestCase {
    private let firstServer = "http://192.168.1.10:8106/"
    private let secondServer = "http://192.168.1.11:8106/"

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func temporaryStorage() throws -> LocalStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LocalStorage(root: root)
    }

    private func sample(_ name: String = "demo.mp4") -> Video {
        Video(name: name, size: 4, contentType: "video/mp4",
              url: "/api/stream/" + name, downloadUrl: "/api/download/" + name)
    }

    @MainActor func testRemovingInactiveServerPreservesCurrentCatalogAcrossRelaunch() throws {
        let disk = try temporaryStorage()
        let defaults = try isolatedDefaults()
        let video = sample()
        defaults.set(firstServer, forKey: "server")
        defaults.set([firstServer, secondServer], forKey: "servers")
        try disk.saveCatalogs([firstServer: [video], secondServer: [sample("other.mp4")]])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)

        store.removeServer("  192.168.1.11:8106  ")

        XCTAssertEqual(store.servers, [firstServer])
        XCTAssertEqual(store.server, firstServer)
        XCTAssertEqual(store.videos, [video])
        XCTAssertFalse(store.loading)
        XCTAssertEqual(defaults.stringArray(forKey: "servers"), [firstServer])
        XCTAssertEqual(defaults.string(forKey: "server"), firstServer)
        XCTAssertNil(store.errorMessage)

        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root),
                                    defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(relaunched.servers, [firstServer])
        XCTAssertEqual(relaunched.server, firstServer)
        XCTAssertEqual(relaunched.videos, [video])
    }

    @MainActor func testRemovingCurrentServerClearsSelectionAndDoesNotRestoreItOnRelaunch() throws {
        let disk = try temporaryStorage()
        let defaults = try isolatedDefaults()
        defaults.set(firstServer, forKey: "server")
        defaults.set([firstServer, secondServer], forKey: "servers")
        try disk.saveCatalogs([firstServer: [sample()], secondServer: [sample("other.mp4")]])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertFalse(store.videos.isEmpty)

        store.removeServer(firstServer)

        XCTAssertEqual(store.servers, [secondServer])
        XCTAssertTrue(store.server.isEmpty)
        XCTAssertTrue(store.videos.isEmpty)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.catalogNotice)
        XCTAssertNil(defaults.object(forKey: "server"))
        XCTAssertNil(store.errorMessage)

        // Even with an old catalog on disk, the deleted current address must not
        // be migrated back into the saved list at the next launch.
        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root),
                                    defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(relaunched.servers, [secondServer])
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertTrue(relaunched.videos.isEmpty)
        XCTAssertFalse(relaunched.loading)
    }

    @MainActor func testRemovingLastServerPreservesLocalVideoMetadataPositionAndPlayback() throws {
        let disk = try temporaryStorage()
        let defaults = try isolatedDefaults()
        var record = DownloadRecord(video: sample(), server: try ServerAddress.normalize(firstServer))
        let bytes = Data([1, 2, 3, 4])
        let temp = disk.root.appendingPathComponent("temporary-download")
        try bytes.write(to: temp)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: firstServer + "api/download/demo.mp4")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4"]))
        try disk.finish(temp: temp, response: response, record: record)
        record.state = .complete
        record.favorite = true
        record.watched = true
        record.pendingDeletionOrder = 1
        record.downloadedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try disk.saveRecords([record])
        defaults.set(firstServer, forKey: "server")
        defaults.set([firstServer], forKey: "servers")
        defaults.set(37.0, forKey: "position." + record.id)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.playLocal(record)
        let playback = try XCTUnwrap(store.playback)

        store.removeServer(firstServer)

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertTrue(store.server.isEmpty)
        XCTAssertTrue(store.videos.isEmpty)
        XCTAssertEqual(store.playback?.id, playback.id)
        XCTAssertEqual(store.records, [record])
        XCTAssertEqual(store.pendingDeletionRecords, [record])
        XCTAssertEqual(defaults.double(forKey: "position." + record.id), 37)
        XCTAssertEqual(try disk.loadRecords(), [record])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(disk.verifiedFile(for: record))), bytes)
        XCTAssertNil(store.errorMessage)
        store.playbackDidClose(playback)

        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root),
                                    defaults: defaults, restoreDownloads: false)
        XCTAssertTrue(relaunched.servers.isEmpty)
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertEqual(relaunched.completed, [record])
        XCTAssertEqual(relaunched.pendingDeletionRecords, [record])
        XCTAssertEqual(defaults.double(forKey: "position." + record.id), 37)
        relaunched.playLocal(record)
        XCTAssertEqual(relaunched.playback?.key, record.id)
        XCTAssertTrue(try XCTUnwrap(relaunched.playback).url.isFileURL)
        XCTAssertNil(relaunched.errorMessage)
    }

    @MainActor func testEquivalentAddressesAreDeduplicatedAndCanBeRemovedAndAddedAgain() throws {
        let disk = try temporaryStorage()
        let defaults = try isolatedDefaults()
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let normalized = "http://example.com/"

        XCTAssertTrue(store.addServer(" HTTP://EXAMPLE.COM:80 "))
        XCTAssertTrue(store.addServer("http://example.com/"))
        XCTAssertEqual(store.servers, [normalized])
        XCTAssertTrue(store.server.isEmpty)

        store.removeServer("http://missing.example/")
        XCTAssertEqual(store.servers, [normalized])
        store.removeServer("EXAMPLE.COM:80")
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "servers"), [])
        XCTAssertTrue(store.addServer("example.com"))

        let relaunched = VideoStore(storage: try LocalStorage(root: disk.root),
                                    defaults: defaults, restoreDownloads: false)
        XCTAssertEqual(relaunched.servers, [normalized])
        XCTAssertTrue(relaunched.server.isEmpty)
        XCTAssertNil(relaunched.errorMessage)
    }
}
