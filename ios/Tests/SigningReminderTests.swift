import Foundation
import XCTest
#if canImport(NiceVideos)
@testable import NiceVideos
#else
@testable import SigningCore
#endif

private actor FakeSigningNotificationClient: SigningNotificationClient {
    var authorization: SigningNotificationPermission
    var requests: [String: SigningReminderRequest] = [:]
    var prompts = 0
    var failAdd = false
    var pauseNextAdd = false
    var addStarted = false
    var addWaiter: CheckedContinuation<Void, Never>?
    var unrelatedNotificationSurvives = true

    init(_ permission: SigningNotificationPermission = .authorized) { authorization = permission }
    func permission() -> SigningNotificationPermission { authorization }
    func requestPermission() { prompts += 1; authorization = .authorized }
    func clear(identifiers: [String]) {
        for id in identifiers { requests[id] = nil }
        if identifiers.contains("another-feature") { unrelatedNotificationSurvives = false }
    }
    func add(_ request: SigningReminderRequest) async throws -> Bool {
        if pauseNextAdd {
            pauseNextAdd = false
            addStarted = true
            await withCheckedContinuation { addWaiter = $0 }
        }
        if failAdd { throw NSError(domain: "synthetic", code: 1) }
        requests[request.identifier] = request
        return true
    }
    func pause() { pauseNextAdd = true }
    func resume() { addWaiter?.resume(); addWaiter = nil }
    func setFailure() { failAdd = true }
    func values() -> [SigningReminderRequest] { Array(requests.values) }
}

final class SigningReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlanOnlyUsesFuture48And24HourDates() {
        for (remainingHours, count) in [(168, 2), (48, 1), (30, 1), (24, 0), (1, 0), (0, 0), (-1, 0)] {
            let expiry = now.addingTimeInterval(Double(remainingHours) * 3600)
            let requests = SigningReminderPlan.requests(expiration: expiry, now: now)
            XCTAssertEqual(requests.count, count)
            for request in requests {
                XCTAssertGreaterThan(request.fireDate, now)
                XCTAssertEqual(expiry.timeIntervalSince(request.fireDate), Double(request.hoursBefore) * 3600)
            }
        }
        XCTAssertTrue(SigningReminderPlan.requests(expiration: nil, now: now).isEmpty)
    }

    @MainActor
    func testNoPermissionPromptAtStartupAndExplicitOptInWorks() async {
        let client = FakeSigningNotificationClient(.notDetermined)
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        let expiry = now.addingTimeInterval(7 * 86400)
        let startup = await scheduler.synchronize(expiration: expiry, enabled: true, now: { now }).value
        XCTAssertTrue(startup.scheduled.isEmpty)
        let before = await client.prompts
        XCTAssertEqual(before, 0)
        let optedIn = await scheduler.synchronize(expiration: expiry, enabled: true,
                                                 requestPermission: true, now: { now }).value
        XCTAssertEqual(optedIn.scheduled.count, 2)
        let after = await client.prompts
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testDeniedPermissionSchedulesNothing() async {
        let client = FakeSigningNotificationClient(.denied)
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        let result = await scheduler.synchronize(expiration: now.addingTimeInterval(7 * 86400),
                                                enabled: true, requestPermission: true, now: { now }).value
        XCTAssertEqual(result.permission, .denied)
        XCTAssertTrue(result.scheduled.isEmpty)
        let prompts = await client.prompts
        XCTAssertEqual(prompts, 0)
    }

    @MainActor
    func testResigningReplacesDatesAndDisableClearsOnlyOwnedNotifications() async {
        let client = FakeSigningNotificationClient()
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        let old = now.addingTimeInterval(3 * 86400)
        let new = now.addingTimeInterval(7 * 86400)
        _ = await scheduler.synchronize(expiration: old, enabled: true, now: { now }).value
        _ = await scheduler.synchronize(expiration: new, enabled: true, now: { now }).value
        let requests = await client.values()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.expirationDate == new })
        _ = await scheduler.synchronize(expiration: new, enabled: false, now: { now }).value
        let disabled = await client.values()
        XCTAssertTrue(disabled.isEmpty)
        let preserved = await client.unrelatedNotificationSurvives
        XCTAssertTrue(preserved)
    }

    @MainActor
    func testUnknownExpirationClearsOldReminders() async {
        let client = FakeSigningNotificationClient()
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        _ = await scheduler.synchronize(expiration: now.addingTimeInterval(7 * 86400), enabled: true, now: { now }).value
        _ = await scheduler.synchronize(expiration: nil, enabled: true, now: { now }).value
        let values = await client.values()
        XCTAssertTrue(values.isEmpty)
    }

    @MainActor
    func testAddFailureDoesNotClaimNotificationsAreScheduled() async {
        let client = FakeSigningNotificationClient()
        await client.setFailure()
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        let result = await scheduler.synchronize(expiration: now.addingTimeInterval(7 * 86400),
                                                enabled: true, now: { now }).value
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.scheduled.isEmpty)
        let values = await client.values()
        XCTAssertTrue(values.isEmpty)
    }

    @MainActor
    func testDisableCannotBeOvertakenByInFlightEnable() async {
        let client = FakeSigningNotificationClient()
        await client.pause()
        let scheduler = SigningReminderScheduler(client: client)
        let now = self.now
        let expiry = now.addingTimeInterval(7 * 86400)
        let enable = scheduler.synchronize(expiration: expiry, enabled: true, now: { now })
        // Bounded wait to make a failed regression fail instead of hanging CI.
        var reachedAdd = false
        for _ in 0..<1_000 {
            if await client.addStarted { reachedAdd = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard reachedAdd else { XCTFail("enable never reached the paused add"); return }
        let disable = scheduler.synchronize(expiration: expiry, enabled: false, now: { now })
        await client.resume()
        _ = await enable.value
        _ = await disable.value
        let values = await client.values()
        XCTAssertTrue(values.isEmpty, "a stale enable must not restore cancelled notifications")
    }
}
