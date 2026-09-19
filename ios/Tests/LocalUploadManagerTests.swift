import XCTest
import Combine
@testable import NiceVideos

private final class UploadMockProtocol: URLProtocol {
    static var status = 201
    static var requests: [URLRequest] = []
    private static let lock = NSLock()
    static func reset(status: Int = 201) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; requests = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.status
        Self.lock.unlock()
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": 1, "uploadID": request.value(forHTTPHeaderField: "X-Nice-Upload-ID") ?? "",
            "name": name, "size": Int64(request.value(forHTTPHeaderField: "X-Nice-Upload-Bytes") ?? "0") ?? 0
        ])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class LocalUploadManagerTests: XCTestCase {
    private func source(_ name: String = "demo.mp4") -> LocalUploadSource {
        LocalUploadSource(id: name, taskToken: name + "|attempt", name: name, size: 4)
    }
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [UploadMockProtocol.self]
        return value
    }
    func testSerialUploadsRequireReceiptAndKeepOriginalFiles() async throws {
        UploadMockProtocol.reset()
        let directory = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("original.mp4")
        try Data([1,2,3,4]).write(to: file)
        var resolved: [String] = []
        var refreshed: Set<URL> = []
        let manager = LocalUploadManager(root: directory.appendingPathComponent("jobs"), configuration: configuration(),
            resolveSource: { job in resolved.append(job.source.id); return file },
            queueFinished: { refreshed = $0 })
        defer { manager.invalidate() }
        let done = expectation(description: "two server receipts")
        var fulfilled = false
        let subscription = manager.$jobs.sink { jobs in
            if jobs.count == 2 && jobs.allSatisfy({ $0.state == .completed }) && !fulfilled {
                fulfilled = true; done.fulfill()
            }
        }
        let server = URL(string: "https://example.test/")!
        XCTAssertTrue(manager.enqueue([source("a.mp4"), source("b.mp4")], server: server, allowsCellular: false))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(resolved, ["a.mp4", "b.mp4"])
        XCTAssertEqual(refreshed, [server])
        XCTAssertEqual(try Data(contentsOf: file), Data([1,2,3,4]))
        XCTAssertEqual(try LocalUploadDisk(root: directory.appendingPathComponent("jobs")).load().map(\.state), [.completed, .completed])
        withExtendedLifetime(subscription) {}
    }
    func testDuplicatePendingSourceIsOnlyEnqueuedOnce() async throws {
        UploadMockProtocol.reset(status: 409)
        let directory = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("original.mp4"); try Data([1,2,3,4]).write(to: file)
        let manager = LocalUploadManager(root: directory.appendingPathComponent("jobs"), configuration: configuration(), resolveSource: { _ in file })
        defer { manager.invalidate() }
        let done = expectation(description: "name conflict")
        var fulfilled = false
        let subscription = manager.$jobs.sink { jobs in
            if jobs.first?.state == .conflict && !fulfilled { fulfilled = true; done.fulfill() }
        }
        XCTAssertTrue(manager.enqueue([source(), source()], server: URL(string: "https://example.test/")!, allowsCellular: false))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertEqual(manager.jobs.first?.state, .conflict)
        XCTAssertEqual(try Data(contentsOf: file), Data([1,2,3,4]))
        withExtendedLifetime(subscription) {}
    }
    func testRelaunchDoesNotAutomaticallyResendUnconfirmedFiles() throws {
        let directory = root(); let disk = try LocalUploadDisk(root: directory)
        var job = LocalUploadJob(source: source(), server: URL(string: "https://old.example/")!, allowsCellular: false)
        job.state = .uploading; try disk.save([job])
        var reads = 0
        let manager = LocalUploadManager(root: directory, configuration: configuration(), resolveSource: { _ in
            reads += 1; throw LocalUploadError("should not read")
        })
        XCTAssertEqual(manager.jobs.first?.state, .failed)
        XCTAssertEqual(manager.jobs.first?.server, job.server)
        XCTAssertEqual(reads, 0)
    }
    func testChangedOrMissingSourceFailsWithoutDeletingAnything() throws {
        let directory = root()
        let manager = LocalUploadManager(root: directory, configuration: configuration(), resolveSource: { _ in
            throw LocalUploadError("download attempt changed")
        })
        XCTAssertTrue(manager.enqueue([source()], server: URL(string: "https://example.test/")!, allowsCellular: false))
        XCTAssertEqual(manager.jobs.first?.state, .failed)
        XCTAssertEqual(manager.jobs.first?.message, "download attempt changed")
    }
}
