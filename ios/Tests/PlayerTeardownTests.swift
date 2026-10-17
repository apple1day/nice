import XCTest
@testable import NiceVideos

private final class RetirementEvents {
    private let lock = NSLock()
    private var values: [(String, Bool)] = []

    func record(_ event: String) {
        lock.lock()
        values.append((event, Thread.isMainThread))
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { $0.0 }
    }

    func wasMain(_ event: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values.first { $0.0 == event }?.1
    }
}

private final class BlockingRetirementResource {
    let events: RetirementEvents
    let entered: XCTestExpectation
    let completed: XCTestExpectation
    let allowRelease: DispatchSemaphore

    init(events: RetirementEvents, entered: XCTestExpectation, completed: XCTestExpectation,
         allowRelease: DispatchSemaphore) {
        self.events = events
        self.entered = entered
        self.completed = completed
        self.allowRelease = allowRelease
    }

    deinit {
        events.record("native release began")
        entered.fulfill()
        let result = allowRelease.wait(timeout: .now() + 5)
        if result == .timedOut { events.record("release gate timed out") }
        events.record("native release completed")
        completed.fulfill()
    }
}

private final class RetirementAttachment {
    let events: RetirementEvents
    let released: XCTestExpectation
    init(events: RetirementEvents, released: XCTestExpectation) {
        self.events = events
        self.released = released
    }
    deinit {
        events.record("attachment released")
        released.fulfill()
    }
}

// Models VLCKit's ownership order: wrapper dealloc releases its own native
// reference first; only then does associated-object disposal release the fence.
private final class LateRetainedPlayerWrapper {
    private var native: BlockingRetirementResource?
    private var lifetime: BackgroundPlaybackResource<BlockingRetirementResource>?
    private let events: RetirementEvents

    init(native: BlockingRetirementResource,
         lifetime: BackgroundPlaybackResource<BlockingRetirementResource>, events: RetirementEvents) {
        self.native = native
        self.lifetime = lifetime
        self.events = events
    }

    deinit {
        events.record("wrapper released")
        native = nil
        lifetime = nil
    }
}

private final class CallbackOwner {
    var wrapper: LateRetainedPlayerWrapper?
}

final class PlayerTeardownTests: XCTestCase {
    func testBlockingNativeReleaseLeavesCallerAndMainQueueResponsive() {
        let events = RetirementEvents()
        let entered = expectation(description: "native release began on worker")
        let completed = expectation(description: "native release finished")
        let attachmentReleased = expectation(description: "attachment released on main")
        let gate = DispatchSemaphore(value: 0)
        var native: BlockingRetirementResource? = BlockingRetirementResource(
            events: events, entered: entered, completed: completed, allowRelease: gate)
        var attachment: RetirementAttachment? = RetirementAttachment(events: events, released: attachmentReleased)
        weak var weakAttachment = attachment
        let owner = BackgroundPlaybackResource(native)
        owner.keepAlive(attachment!)
        native = nil
        attachment = nil

        XCTAssertTrue(owner.retire())
        events.record("retire returned")
        XCTAssertNil(owner.resource)
        wait(for: [entered], timeout: 2)
        XCTAssertNotNil(weakAttachment, "The drawable must survive a blocked decoder destructor")

        let mainResponded = expectation(description: "main queue still accepts UI work")
        DispatchQueue.main.async { mainResponded.fulfill() }
        wait(for: [mainResponded], timeout: 2)
        XCTAssertFalse(events.names.contains("native release completed"))
        gate.signal()
        wait(for: [completed, attachmentReleased], timeout: 2)

        XCTAssertEqual(events.wasMain("native release began"), false)
        XCTAssertEqual(events.wasMain("native release completed"), false)
        XCTAssertEqual(events.wasMain("attachment released"), true)
        XCTAssertNil(weakAttachment)
        XCTAssertFalse(events.names.contains("release gate timed out"))
        XCTAssertLessThan(events.names.firstIndex(of: "native release completed")!,
                          events.names.firstIndex(of: "attachment released")!)
    }

    func testRetirementIsIdempotentAndRejectsLateResourceAccess() {
        let entered = expectation(description: "released once")
        let completed = expectation(description: "completed once")
        entered.assertForOverFulfill = true
        completed.assertForOverFulfill = true
        let events = RetirementEvents()
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        var native: BlockingRetirementResource? = BlockingRetirementResource(
            events: events, entered: entered, completed: completed, allowRelease: gate)
        let owner = BackgroundPlaybackResource(native)
        XCTAssertNotNil(owner.resource)
        native = nil

        XCTAssertTrue(owner.retire())
        for _ in 0..<20 {
            XCTAssertFalse(owner.retire())
            XCTAssertNil(owner.resource)
        }
        wait(for: [entered, completed], timeout: 2)
        XCTAssertEqual(events.names.filter { $0 == "native release completed" }.count, 1)
    }

    func testOwnerDeinitAlsoTransfersReleaseWithoutWaiting() {
        let events = RetirementEvents()
        let entered = expectation(description: "native release began")
        let completed = expectation(description: "native release completed")
        let gate = DispatchSemaphore(value: 0)
        var native: BlockingRetirementResource? = BlockingRetirementResource(
            events: events, entered: entered, completed: completed, allowRelease: gate)
        var owner: BackgroundPlaybackResource? = BackgroundPlaybackResource(native)
        native = nil
        XCTAssertNotNil(owner?.resource)
        owner = nil
        events.record("owner deinit returned")
        wait(for: [entered], timeout: 2)
        XCTAssertTrue(events.names.contains("owner deinit returned"))
        XCTAssertFalse(events.names.contains("native release completed"))
        gate.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(events.wasMain("native release began"), false)
    }

    func testLateMainQueueWrapperOwnerCannotMoveFinalNativeReleaseOntoMain() {
        let queue = DispatchQueue(label: "nice.teardown.late-owner-test")
        let events = RetirementEvents()
        let entered = expectation(description: "final native release began")
        let completed = expectation(description: "final native release completed")
        let attachmentReleased = expectation(description: "drawable released after native")
        let gate = DispatchSemaphore(value: 0)
        var native: BlockingRetirementResource? = BlockingRetirementResource(
            events: events, entered: entered, completed: completed, allowRelease: gate)
        var attachment: RetirementAttachment? = RetirementAttachment(events: events, released: attachmentReleased)
        weak var weakAttachment = attachment
        var lifetime: BackgroundPlaybackResource? = BackgroundPlaybackResource(native, releaseQueue: queue)
        lifetime?.keepAlive(attachment!)
        var wrapper: LateRetainedPlayerWrapper? = LateRetainedPlayerWrapper(
            native: native!, lifetime: lifetime!, events: events)
        let owner = BackgroundPlaybackResource(wrapper, releaseQueue: queue)
        let lateCallback = CallbackOwner()
        lateCallback.wrapper = wrapper
        native = nil
        lifetime = nil
        attachment = nil
        wrapper = nil

        owner.retire()
        let ownerReleased = expectation(description: "background wrapper ownership relinquished")
        queue.async { ownerReleased.fulfill() }
        wait(for: [ownerReleased], timeout: 2)
        XCTAssertFalse(events.names.contains("wrapper released"))
        XCTAssertFalse(events.names.contains("native release began"))
        XCTAssertNotNil(weakAttachment)

        // The exact upstream hazard: an idle-timer/callback block on main owns
        // the last ObjC wrapper reference after our background handoff finishes.
        DispatchQueue.main.async { lateCallback.wrapper = nil }
        wait(for: [entered], timeout: 2)
        XCTAssertEqual(events.wasMain("wrapper released"), true)
        XCTAssertEqual(events.wasMain("native release began"), false)
        XCTAssertNotNil(weakAttachment)
        gate.signal()
        wait(for: [completed, attachmentReleased], timeout: 2)
        XCTAssertEqual(events.wasMain("attachment released"), true)
        XCTAssertNil(weakAttachment)
        XCTAssertLessThan(events.names.firstIndex(of: "wrapper released")!,
                          events.names.firstIndex(of: "native release began")!)
        XCTAssertLessThan(events.names.firstIndex(of: "native release completed")!,
                          events.names.firstIndex(of: "attachment released")!)
    }
}
