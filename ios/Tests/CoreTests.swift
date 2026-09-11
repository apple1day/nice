import XCTest
@testable import NiceVideos

final class CoreTests: XCTestCase {
    private func sample(_ name: String = "demo.mp4", size: Int64 = 4) -> Video {
        Video(name: name, size: size, contentType: "video/mp4",
              url: "/api/stream/demo.mp4", downloadUrl: "/api/download/demo.mp4")
    }

    private func response(status: Int = 200, mime: String = "video/mp4") throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/api/download/demo.mp4")!,
                                     statusCode: status, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": mime]))
    }

    func testDecodesActualAPIEnvelopeWithoutTrustingServerDownloaded() throws {
        let data = Data(#"{"videos":[{"name":"demo.mp4","size":4,"contentType":"video/mp4","url":"/api/stream/demo.mp4","downloadUrl":"/api/download/demo.mp4","downloaded":true,"downloadedAt":"2026-09-11T10:00:00Z"}]}"#.utf8)
        let result = try JSONDecoder().decode(VideoEnvelope.self, from: data)
        XCTAssertEqual(result.videos.count, 1)
        XCTAssertEqual(result.videos[0].size, 4)
        // Decoding a remote history flag cannot create a local DownloadRecord.
        XCTAssertEqual(result.videos[0].name, "demo.mp4")
    }

    func testEmptyCatalog() throws {
        XCTAssertTrue(try JSONDecoder().decode(VideoEnvelope.self, from: Data(#"{"videos":[]}"#.utf8)).videos.isEmpty)
    }

    func testNormalizeOriginAndDefaultPort() throws {
        XCTAssertEqual(try ServerAddress.normalize("  192.168.1.10:8106  ").absoluteString,
                       "http://192.168.1.10:8106/")
        XCTAssertEqual(try ServerAddress.normalize("HTTPS://EXAMPLE.COM:443/").absoluteString,
                       "https://example.com/")
    }

    func testRejectNonRootOrCredentialURLs() {
        for input in ["", "file:///tmp/test", "https://u:p@example.com", "https://example.com/api/videos",
                      "https://example.com/?token=secret", "https://example.com/#fragment"] {
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

    func testUnsupportedFormatsCannotBecomeFakeOfflineDownloads() {
        XCTAssertTrue(sample("test.MP4").supportsOffline)
        XCTAssertTrue(sample("test.mov").supportsOffline)
        XCTAssertFalse(sample("test.mkv").supportsOffline)
        XCTAssertFalse(sample("test.avi").supportsOffline)
        XCTAssertFalse(sample("test.m3u8").supportsOffline)
        XCTAssertFalse(sample(size: 0).supportsOffline)
        let disguisedHLS = Video(name: "test.mp4", size: 4, contentType: "application/vnd.apple.mpegurl",
                                 url: "/api/stream/test.mp4", downloadUrl: "/api/download/test.mp4")
        XCTAssertFalse(disguisedHLS.supportsOffline)
    }

    func testDownloadValidationRejectsHTTPErrorHTMLAndTruncation() throws {
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(status: 404), actualSize: 4, expectedSize: 4))
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(mime: "text/html"), actualSize: 4, expectedSize: 4))
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(mime: "application/json"), actualSize: 4, expectedSize: 4))
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(mime: "application/vnd.apple.mpegurl"), actualSize: 4, expectedSize: 4))
        XCTAssertThrowsError(try LocalStorage.validateDownload(response: response(), actualSize: 3, expectedSize: 4))
        XCTAssertNoThrow(try LocalStorage.validateDownload(response: response(), actualSize: 4, expectedSize: 4))
    }

    func testLocalFileAndIndexSurviveNewStorageInstanceWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LocalStorage(root: root)
        var record = DownloadRecord(video: sample(), server: try ServerAddress.normalize("https://example.com"))
        let temp = root.appendingPathComponent("temporary-download")
        try Data([1, 2, 3, 4]).write(to: temp)
        try disk.finish(temp: temp, response: response(), record: record)
        record.state = .complete
        try disk.saveRecords([record])
        let relaunched = try LocalStorage(root: root)
        let loaded = try XCTUnwrap(relaunched.loadRecords().first)
        let local = try XCTUnwrap(relaunched.verifiedFile(for: loaded))
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(try Data(contentsOf: local), Data([1, 2, 3, 4]))
        try relaunched.remove(loaded)
        XCTAssertNil(relaunched.verifiedFile(for: loaded))
    }

    func testIncompleteFileIsNotAvailableOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LocalStorage(root: root)
        let record = DownloadRecord(video: sample(), server: try ServerAddress.normalize("https://example.com"))
        try Data([1, 2]).write(to: disk.destination(for: record))
        XCTAssertNil(disk.verifiedFile(for: record))
    }

    func testCorruptManifestIsNotSilentlyOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LocalStorage(root: root)
        let file = root.appendingPathComponent("downloads.json")
        let corrupt = Data("{unfinished".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try disk.loadRecords())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testNewAttemptDoesNotReuseOldTaskToken() throws {
        let base = try ServerAddress.normalize("https://example.com")
        let first = DownloadRecord(video: sample(), server: base)
        let retry = DownloadRecord(video: sample(), server: base)
        XCTAssertEqual(first.id, retry.id)
        XCTAssertNotEqual(first.taskToken, retry.taskToken)
    }
}
