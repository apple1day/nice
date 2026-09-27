import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NiceVideos

final class LocalUploadPolicyTests: XCTestCase {
    private func job(name: String = "demo.mp4", size: Int64 = 4, server: String = "http://127.0.0.1:8106/") -> LocalUploadJob {
        LocalUploadJob(source: LocalUploadSource(id: "source", taskToken: "source|attempt", name: name, size: size),
                       server: URL(string: server)!, allowsCellular: false)
    }
    private func response(_ job: LocalUploadJob, status: Int = 201, mime: String = "application/json") throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try LocalUploadWire.request(for: job).url!, statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime]))
    }
    private func receipt(_ job: LocalUploadJob, name: String? = nil, size: Int64? = nil, id: UUID? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "uploadID": (id ?? job.id).uuidString,
                                                     "name": name ?? job.source.name, "size": size ?? job.source.size])
    }
    private func disk() throws -> LocalUploadDisk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LocalUploadDisk(root: root)
    }
    func testSpecialNamesUseQueryEncodingExactlyOnce() throws {
        let request = try LocalUploadWire.request(for: job(name: "中文 a+b%#?.MP4"))
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value, "中文 a+b%#?.MP4")
        XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
        XCTAssertTrue(request.url!.absoluteString.contains("%25"))
        XCTAssertNil(components.fragment)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertFalse(request.allowsCellularAccess)
    }
    func testRejectsUnsafeNamesAndPlaylists() {
        for name in ["../a.mp4", "a/b.mp4", "a\\b.mp4", ".hidden.mp4", "a\n.mp4", "a.m3u8", "a.zip", ""] {
            XCTAssertThrowsError(try LocalUploadWire.request(for: job(name: name)), name)
        }
    }
    func testRejectsInvalidOriginAndSizes() {
        for server in ["file:///tmp/", "https://user:password@example.com/", "https://example.com/path", "https://example.com/?x=1", "https://example.com/#x"] {
            XCTAssertThrowsError(try LocalUploadWire.request(for: job(server: server)))
        }
        for size in [Int64(0), -1, LocalUploadWire.maximumBytes + 1] {
            XCTAssertThrowsError(try LocalUploadWire.request(for: job(size: size)))
        }
        XCTAssertNoThrow(try LocalUploadWire.request(for: job(size: 3 * 1024 * 1024 * 1024)))
    }
    func testOnlyMatchingCreatedReceiptCountsAsSuccess() throws {
        let item = job()
        XCTAssertNoThrow(try LocalUploadWire.validateReceipt(receipt(item), response: response(item), job: item))
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(receipt(item, name: "other.mp4"), response: response(item), job: item))
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(receipt(item, size: 1), response: response(item), job: item))
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(receipt(item, id: UUID()), response: response(item), job: item))
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(Data("<html>ok</html>".utf8), response: response(item), job: item))
    }
    func testHTTPFailuresAreNotSuccessfulUploads() throws {
        let item = job()
        for status in [200, 204, 301, 307, 400, 401, 404, 405, 409, 413, 429, 500, 507] {
            XCTAssertThrowsError(try LocalUploadWire.validateReceipt(receipt(item), response: response(item, status: status), job: item))
        }
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(receipt(item), response: response(item, mime: "text/html"), job: item))
    }
    func testReceiptSizeIsBounded() throws {
        let item = job()
        XCTAssertThrowsError(try LocalUploadWire.validateReceipt(Data(repeating: 32, count: LocalUploadWire.responseLimit + 1),
                                                                 response: response(item), job: item))
    }
    func testSnapshotSurvivesLibraryDeletionAndDoesNotCopyBytes() throws {
        let storage = try disk(); let source = storage.root.appendingPathComponent("source.mp4")
        try Data([0, 1, 2, 3]).write(to: source)
        let id = UUID(); let snapshot = try storage.prepare(source: source, id: id, expectedBytes: 4)
        let a = try FileManager.default.attributesOfItem(atPath: source.path)
        let b = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        XCTAssertEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: snapshot), Data([0, 1, 2, 3]))
        try storage.removeSnapshot(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }
    func testSnapshotRefusesMissingChangedAndSymbolicFiles() throws {
        let storage = try disk(); let source = storage.root.appendingPathComponent("source.mp4")
        XCTAssertThrowsError(try storage.prepare(source: source, id: UUID(), expectedBytes: 4))
        try Data([1, 2]).write(to: source)
        XCTAssertThrowsError(try storage.prepare(source: source, id: UUID(), expectedBytes: 4))
        let link = storage.root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try storage.prepare(source: link, id: UUID(), expectedBytes: 2))
    }
    func testSameIDSnapshotCannotOverwriteEarlierSnapshot() throws {
        let storage = try disk(); let source = storage.root.appendingPathComponent("source.mp4")
        try Data([1, 2]).write(to: source)
        let id = UUID(); _ = try storage.prepare(source: source, id: id, expectedBytes: 2)
        XCTAssertThrowsError(try storage.prepare(source: source, id: id, expectedBytes: 2))
    }
    func testManifestRestoresCapturedDestinationAndSourceAttempt() throws {
        let storage = try disk(); let item = job()
        try storage.save([item])
        let restored = try LocalUploadDisk(root: storage.root).load()
        XCTAssertEqual(restored, [item])
        XCTAssertFalse(item.matches(LocalUploadSource(id: "source", taskToken: "new-attempt", name: "demo.mp4", size: 4), server: item.server))
        XCTAssertFalse(item.matches(item.source, server: URL(string: "https://other.example/")!))
    }
    func testCorruptManifestIsNotOverwritten() throws {
        let storage = try disk(); let file = storage.root.appendingPathComponent("uploads.json")
        let broken = Data("{invalid".utf8); try broken.write(to: file)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testRecoveryRemovesOnlyOwnSnapshotLinks() throws {
        let storage = try disk(); let source = storage.root.appendingPathComponent("original.mp4")
        try Data([1, 2]).write(to: source)
        let snapshot = try storage.prepare(source: source, id: UUID(), expectedBytes: 2)
        try storage.recoverAfterRelaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
    }
}
