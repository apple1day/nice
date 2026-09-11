import XCTest
@testable import NiceVideos

final class CoreTests: XCTestCase {
    private func sample(_ name: String = "demo.mp4", size: Int64 = 4) -> Video {
        Video(name: name, size: size, contentType: "video/mp4",
              url: "/api/stream/demo.mp4", downloadUrl: "/api/download/demo.mp4")
    }
    private func response(status: Int = 200, mime: String = "video/mp4") throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/api/download/demo.mp4")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime]))
    }
    private func fixture() throws -> (LocalStorage, DownloadRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let disk = try LocalStorage(root: root)
        var record = DownloadRecord(video: sample(), server: try ServerAddress.normalize("http://127.0.0.1:9"))
        let temp = root.appendingPathComponent("temporary-download")
        try Data([1, 2, 3, 4]).write(to: temp)
        try disk.finish(temp: temp, response: response(), record: record)
        record.state = .complete
        try disk.saveRecords([record])
        return (disk, record)
    }
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testDecodesAPIWithoutTrustingServerDownloaded() throws {
        let data = Data(#"{"videos":[{"name":"demo.mp4","size":4,"contentType":"video/mp4","url":"/api/stream/demo.mp4","downloadUrl":"/api/download/demo.mp4","downloaded":true,"downloadedAt":"2026-09-11T10:00:00Z"}]}"#.utf8)
        let result = try JSONDecoder().decode(VideoEnvelope.self, from: data)
        XCTAssertEqual(result.videos.count, 1)
        XCTAssertEqual(result.videos[0].name, "demo.mp4")
    }
    func testEmptyCatalog() throws {
        XCTAssertTrue(try JSONDecoder().decode(VideoEnvelope.self, from: Data(#"{"videos":[]}"#.utf8)).videos.isEmpty)
    }
    func testNormalizeOriginAndDefaultPort() throws {
        XCTAssertEqual(try ServerAddress.normalize("  192.168.19.70:8106  ").absoluteString, "http://192.168.19.70:8106/")
        XCTAssertEqual(try ServerAddress.normalize("HTTPS://EXAMPLE.COM:443/").absoluteString, "https://example.com/")
    }
    func testRejectNonRootOrCredentialURLs() {
        for input in ["", "file:///tmp/test", "https://u:p@example.com", "https://example.com/api/videos", "https://example.com/?a=1"] {
            XCTAssertThrowsError(try ServerAddress.normalize(input), input)
        }
    }
    func testPreservesEncodedFilenameExactlyOnce() throws {
        let server = try ServerAddress.normalize("https://example.com")
        let path = "/api/download/%E4%B8%AD%E6%96%87%20a+b%25%23.mp4"
        let url = try ServerAddress.endpoint(path, on: server)
        XCTAssertEqual(url.absoluteString, "https://example.com" + path)
        XCTAssertEqual(url.path, "/api/download/中文 a+b%#.mp4")
    }
    func testRejectsOffOriginEndpoints() throws {
        let base = try ServerAddress.normalize("https://example.com")
        for path in ["https://other.example/api/video", "//other.example/api/video", "/video.mp4", "/api/a#fragment"] {
            XCTAssertThrowsError(try ServerAddress.endpoint(path, on: base))
        }
    }
    func testIdentitySeparatesServersAndSizes() throws {
        let first = try ServerAddress.normalize("http://192.168.1.10:8106")
        let second = try ServerAddress.normalize("http://192.168.1.11:8106")
        XCTAssertNotEqual(sample().storageID(server: first), sample().storageID(server: second))
        XCTAssertNotEqual(sample().storageID(server: first), sample(size: 8).storageID(server: first))
        XCTAssertEqual(sample().storageID(server: first).count, 64)
    }
    func testVLCContainerPolicyAndPlaylistRejection() {
        for ext in ["MP4", "m4v", "mov", "mkv", "avi", "webm", "ogg", "flv", "wmv", "ts"] {
            XCTAssertTrue(sample("test." + ext).supportsOffline, ext)
        }
        for ext in ["m3u8", "m3u", "mpd", "pls", "html", "zip"] {
            XCTAssertFalse(sample("test." + ext).supportsOffline, ext)
        }
        XCTAssertFalse(sample(size: 0).supportsOffline)
        XCTAssertFalse(OfflineMediaPolicy.supports(name: "fake.mp4", size: 4, contentType: "application/vnd.apple.mpegurl"))
        XCTAssertFalse(OfflineMediaPolicy.supports(name: "fake.mp4", size: 4, contentType: "application/dash+xml"))
    }
    func testDownloadRejectsHTTPErrorsTextAndTruncation() throws {
        for status in [206, 302, 401, 404, 500] {
            XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(status: status), actualSize: 4, expectedSize: 4))
        }
        for mime in ["text/html", "application/json", "application/vnd.apple.mpegurl", "application/dash+xml"] {
            XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(mime: mime), actualSize: 4, expectedSize: 4))
        }
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(), actualSize: 3, expectedSize: 4))
        XCTAssertNoThrow(try LocalStorage.validateDownload(response: response(), actualSize: 4, expectedSize: 4))
    }
    func testLocalFileAndV1ManifestSurviveRelaunch() throws {
        let (disk, record) = try fixture()
        let relaunched = try LocalStorage(root: disk.root)
        let loaded = try XCTUnwrap(relaunched.loadRecords().first)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.taskToken, record.taskToken)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(relaunched.verifiedFile(for: loaded))), Data([1, 2, 3, 4]))
        let manifest = try JSONDecoder().decode(DownloadManifest.self, from: Data(contentsOf: disk.root.appendingPathComponent("downloads.json")))
        XCTAssertEqual(manifest.version, 1)
    }
    func testIncompleteFileNotAvailableOffline() throws {
        let (disk, record) = try fixture()
        try Data([1, 2]).write(to: disk.destination(for: record))
        XCTAssertNil(disk.verifiedFile(for: record))
    }
    func testCorruptManifestIsPreserved() throws {
        let (disk, _) = try fixture()
        let path = disk.root.appendingPathComponent("downloads.json")
        let corrupt = Data("{unfinished".utf8)
        try corrupt.write(to: path)
        XCTAssertThrowsError(try disk.loadRecords())
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }
    func testNewAttemptHasNewTaskToken() throws {
        let server = try ServerAddress.normalize("https://example.com")
        let first = DownloadRecord(video: sample(), server: server)
        let next = DownloadRecord(video: sample(), server: server)
        XCTAssertEqual(first.id, next.id)
        XCTAssertNotEqual(first.taskToken, next.taskToken)
    }
    func testPlaybackRequestRejectsRemoteURLs() {
        for address in ["http://192.168.19.70:8106/api/stream/a.mp4", "https://example.com/a.mp4", "file://remote-host/a.mp4"] {
            XCTAssertThrowsError(try PlaybackRequest(key: "id", title: "test", url: URL(string: address)!))
        }
    }
    func testPlaybackRequestRejectsMissingFileAndSymlink() throws {
        let (disk, record) = try fixture()
        let path = try disk.destination(for: record)
        let link = disk.root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try PlaybackRequest(key: "id", title: "test", url: link))
        try disk.remove(record)
        XCTAssertThrowsError(try PlaybackRequest(key: "id", title: "test", url: path))
    }
    func testDisguisedPlaylistOrErrorPageIsRejected() throws {
        let (disk, record) = try fixture()
        let path = try disk.destination(for: record)
        for text in ["#EXTM3U\nhttps://example.com/a.ts", "[playlist]", "<?xml version='1.0'?><MPD/>", "<html>Error</html>", "{\"error\":true}"] {
            try Data(text.utf8).write(to: path)
            XCTAssertThrowsError(try PlaybackRequest(key: "id", title: "test", url: path))
        }
    }
    @MainActor func testColdStartPlaysLocalWithUnreachableServerAndNoCatalog() throws {
        let (disk, record) = try fixture()
        let defaults = try isolatedDefaults()
        defaults.set(record.server, forKey: "server") // Nothing listens on port 9.
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        XCTAssertFalse(store.loading)
        XCTAssertTrue(store.videos.isEmpty)
        store.playLocal(record)
        XCTAssertTrue(try XCTUnwrap(store.playback).url.isFileURL)
        XCTAssertNil(store.errorMessage)
        let second = VideoStore(storage: try LocalStorage(root: disk.root), defaults: defaults, restoreDownloads: false)
        second.playLocal(record)
        XCTAssertEqual(second.playback?.key, record.id)
    }
    @MainActor func testMissingDownloadNeverFallsBackToStreaming() throws {
        let (disk, record) = try fixture()
        try disk.remove(record)
        let defaults = try isolatedDefaults()
        defaults.set(record.server, forKey: "server")
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.play(record.video)
        XCTAssertNil(store.playback)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.completed.isEmpty)
    }
    @MainActor func testLocalPlaybackDoesNotRequireConfiguredServer() throws {
        let (disk, record) = try fixture()
        let store = VideoStore(storage: disk, defaults: try isolatedDefaults(), restoreDownloads: false)
        XCTAssertTrue(store.server.isEmpty)
        store.playLocal(record)
        XCTAssertEqual(store.playback?.key, record.id)
    }
    @MainActor func testDeleteOnlyRemovesLocalRecordAndPosition() throws {
        let (disk, record) = try fixture()
        let defaults = try isolatedDefaults()
        defaults.set(20.0, forKey: "position." + record.id)
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.removeFromDevice(record)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(disk.verifiedFile(for: record))
        XCTAssertNil(defaults.object(forKey: "position." + record.id))
    }
    func testPositionBoundsAndFormatting() {
        XCTAssertEqual(PlaybackPosition.resume(saved: 20, duration: 100), 20)
        for value in [0.0, -1, 99, .nan, .infinity] {
            XCTAssertNil(PlaybackPosition.resume(saved: value, duration: 100))
        }
        XCTAssertEqual(PlaybackPosition.clamp(-5, duration: 100), 0)
        XCTAssertEqual(PlaybackPosition.clamp(200, duration: 100), 99.9)
        XCTAssertNil(PlaybackPosition.clamp(.nan, duration: 100))
        XCTAssertNil(PlaybackPosition.clamp(10, duration: 0))
        XCTAssertEqual(PlaybackPosition.label(3661), "1:01:01")
        XCTAssertEqual(PlaybackPosition.label(.infinity), "00:00")
    }
}
