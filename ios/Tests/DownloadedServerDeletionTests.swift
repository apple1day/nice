import XCTest
@testable import NiceVideos

final class DownloadedServerDeletionTests: XCTestCase {
    private let server = "http://192.168.1.10:8106/"
    private let otherServer = "http://192.168.1.20:8106/"

    private func video(_ name: String = "video.mp4", size: Int64 = 128) -> Video {
        Video(name: name, size: size, contentType: "video/mp4",
              url: "/api/stream/" + name, downloadUrl: "/api/download/" + name)
    }

    private func record(_ video: Video, server: String? = nil, state: DownloadState = .complete) throws -> DownloadRecord {
        var record = DownloadRecord(video: video, server: try ServerAddress.normalize(server ?? self.server))
        record.state = state
        return record
    }

    func testOnlyCompletedCurrentServerVideosAreSelected() throws {
        let a = video("a.mp4"), b = video("b.mp4"), c = video("c.mp4")
        let completed = try record(a)
        let records = [completed, try record(b, state: .downloading), try record(c, state: .failed),
                       try record(a, server: otherServer), try record(video("removed.mp4"))]
        let plan = DownloadedServerDeletionPlan(server: server, videos: [a, b, c], records: records)
        XCTAssertEqual(plan.records.map(\.taskToken), [completed.taskToken])
    }

    func testSameNameWithChangedSizeIsNotSelected() throws {
        let old = try record(video(size: 128))
        let plan = DownloadedServerDeletionPlan(server: server, videos: [video(size: 256)], records: [old])
        XCTAssertTrue(plan.records.isEmpty)
    }

    func testPendingAndFavoriteVideosRemainEligibleWithoutChangingTheirFlags() throws {
        var local = try record(video())
        local.pendingDeletionOrder = 3
        local.favorite = true
        local.watched = true
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local])
        XCTAssertEqual(plan.records, [local])
    }

    func testInvalidServerAndDuplicateRecordsAreSafe() throws {
        let local = try record(video())
        XCTAssertTrue(DownloadedServerDeletionPlan(server: "", videos: [local.video], records: [local]).records.isEmpty)
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local, local])
        XCTAssertEqual(plan.records.count, 1)
    }

    @MainActor
    func testSuccessfulDeletionLeavesLocalRecordsUnchanged() async throws {
        var local = try record(video())
        local.pendingDeletionOrder = 0
        local.favorite = true
        let before = local
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local])
        var verified: [String] = [], deleted: [String] = []
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
            currentRecord: { _ in local }, verifyLocalFile: { verified.append($0.id) },
            deleteRemote: { deleted.append($0.name) })
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(verified, [local.id])
        XCTAssertEqual(deleted, [local.video.name])
        XCTAssertEqual(local, before)
    }

    @MainActor
    func testMissingLocalFileNeverDeletesServerCopy() async throws {
        let local = try record(video())
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local])
        var sent = false
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
            currentRecord: { _ in local }, verifyLocalFile: { _ in throw ClientError("missing file") },
            deleteRemote: { _ in sent = true })
        XCTAssertFalse(sent)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.deleted, 0)
    }

    @MainActor
    func testStaleDownloadAttemptAndRemovedRecordAreSkipped() async throws {
        let a = try record(video("a.mp4")), b = try record(video("b.mp4"))
        let replacement = try record(a.video)
        let plan = DownloadedServerDeletionPlan(server: server, videos: [a.video, b.video], records: [a, b])
        var sent = false
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
            currentRecord: { $0.id == a.id ? replacement : nil },
            verifyLocalFile: { _ in XCTFail("Stale records must not be verified") },
            deleteRemote: { _ in sent = true })
        XCTAssertFalse(sent)
        XCTAssertEqual(result.skipped, 2)
    }

    @MainActor
    func testDownloadStateChangedAfterConfirmationIsSkipped() async throws {
        let local = try record(video())
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local])
        for state in [DownloadState.downloading, .failed] {
            var changed = local
            changed.state = state
            let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
                currentRecord: { _ in changed }, verifyLocalFile: { _ in XCTFail("Must skip changed state") },
                deleteRemote: { _ in XCTFail("Must not delete") })
            XCTAssertEqual(result.skipped, 1)
        }
    }

    @MainActor
    func testFailureDoesNotStopLaterDeletions() async throws {
        let records = try [record(video("a.mp4")), record(video("b.mp4")), record(video("c.mp4"))]
        let plan = DownloadedServerDeletionPlan(server: server, videos: records.map(\.video), records: records)
        var requested: [String] = []
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
            currentRecord: { $0 }, verifyLocalFile: { _ in }, deleteRemote: {
                requested.append($0.name)
                if $0.name == "b.mp4" { throw ClientError("HTTP 500") }
            })
        XCTAssertEqual(requested, ["a.mp4", "b.mp4", "c.mp4"])
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("b.mp4"))
    }

    @MainActor
    func testServerSwitchBeforeConfirmationSendsNoDelete() async throws {
        let local = try record(video())
        let plan = DownloadedServerDeletionPlan(server: server, videos: [local.video], records: [local])
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.otherServer },
            currentRecord: { $0 }, verifyLocalFile: { _ in XCTFail("Wrong server") },
            deleteRemote: { _ in XCTFail("Wrong server must not be deleted") })
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.deleted, 0)
    }

    @MainActor
    func testServerSwitchDuringBatchStopsRemainingRequests() async throws {
        let records = try [record(video("a.mp4")), record(video("b.mp4"))]
        let plan = DownloadedServerDeletionPlan(server: server, videos: records.map(\.video), records: records)
        var selected = server
        var requested: [String] = []
        let result = await DownloadedServerDeletion.run(plan, currentServer: { selected },
            currentRecord: { $0 }, verifyLocalFile: { _ in }, deleteRemote: {
                requested.append($0.name)
                selected = self.otherServer
            })
        XCTAssertEqual(requested, ["a.mp4"])
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    @MainActor
    func testNewDownloadAfterConfirmationIsNotIncluded() async throws {
        let first = try record(video("a.mp4")), later = try record(video("b.mp4"))
        let plan = DownloadedServerDeletionPlan(server: server, videos: [first.video, later.video], records: [first])
        let current = [first, later]
        var requested: [String] = []
        let result = await DownloadedServerDeletion.run(plan, currentServer: { self.server },
            currentRecord: { snapshot in current.first { $0.id == snapshot.id } }, verifyLocalFile: { _ in },
            deleteRemote: { requested.append($0.name) })
        XCTAssertEqual(requested, ["a.mp4"])
        XCTAssertEqual(result.deleted, 1)
    }
}
