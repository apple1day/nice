import XCTest
import Combine
@testable import NiceVideos

// Keep transport local while CFNetwork creates the real download task, response
// and temporary file handed to the production URLSessionDownloadDelegate.
private final class FilesMovieProtocol: URLProtocol {
    static let movie = Bundle(for: FilesMovieProtocol.self).url(forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let movie = Self.movie, let bytes = try? Data(contentsOf: movie),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "video/mp4", "Content-Length": String(bytes.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FilesIntegrationTests: XCTestCase {
    func testBuiltAppExposesItsDocumentsInFiles() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(info?["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info?["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
    }

    func testDefaultStoragePutsNamedVideoInDocumentsAndIndexInPrivateStorage() throws {
        let disk = try LocalStorage()
        let video = Video(name: "全景 旅行 \(UUID().uuidString).mp4", size: 4, contentType: "video/mp4",
                          url: "", downloadUrl: "/api/download/sample")
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        let file = try disk.destination(for: DownloadRecord(video: video, server: server))
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
        let expected = documents.appendingPathComponent("下载", isDirectory: true).appendingPathComponent(video.name)
        XCTAssertEqual(file.standardizedFileURL, expected.standardizedFileURL)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        XCTAssertTrue(disk.root.standardizedFileURL.pathComponents.starts(with: support.standardizedFileURL.pathComponents))
    }

    @MainActor func testDownloadDelegatePublishesMovieInFilesAndKeepsRecordAfterExternalDeletion() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        let documents = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let disk = try LocalStorage(root: sandbox.appendingPathComponent("Private", isDirectory: true), documents: documents)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = try Data(contentsOf: XCTUnwrap(FilesMovieProtocol.movie))
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        let video = Video(name: "旅行 片段.mp4", size: Int64(bytes.count), contentType: "video/mp4",
                          url: "", downloadUrl: "/api/download/movie")
        let record = DownloadRecord(video: video, server: server)
        try disk.saveRecords([record])
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilesMovieProtocol.self]
        let session = URLSession(configuration: config, delegate: store, delegateQueue: .main)
        defer { session.finishTasksAndInvalidate() }
        let finished = expectation(description: "Download delegate finished publishing the movie")
        let subscription = store.$records.first { $0.first?.state != .downloading }.sink { _ in finished.fulfill() }
        defer { subscription.cancel() }
        let task = session.downloadTask(with: try ServerAddress.endpoint(video.downloadUrl, on: server))
        task.taskDescription = record.taskToken
        task.resume()
        await fulfillment(of: [finished], timeout: 10)

        let stored = try XCTUnwrap(disk.loadRecords().first)
        XCTAssertEqual(stored.state, .complete, stored.message ?? "")
        let folder = documents.appendingPathComponent("下载", isDirectory: true)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: documents.path), ["下载"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [video.name])
        let movie = folder.appendingPathComponent(video.name)
        XCTAssertEqual(try Data(contentsOf: movie), bytes)
        XCTAssertEqual(try store.localPlaybackRequest(for: record.id).url, movie)

        try fm.removeItem(at: movie)
        await store.refreshDownloadedFiles()
        XCTAssertEqual(try disk.loadRecords().map(\.id), [record.id])
        XCTAssertEqual(store.records.first?.state, .missing)
        XCTAssertEqual(LocalLibraryModel(store: store).visibleRows.first?.record.state, .missing)
    }
}
