import XCTest
import UIKit
@testable import NiceVideos

private final class ScrubObserver: PlaybackScrubObserver {
    var drafts: [Double?] = []
    var editing: [Bool] = []
    var commits: [Double] = []
    func draftChanged(_ seconds: Double?) { drafts.append(seconds) }
    func editingChanged(_ value: Bool) { editing.append(value) }
    func commit(_ seconds: Double) { commits.append(seconds) }
}

// These exercise the real UISlider target-action and lifecycle implementation.
// Only the OS's initial touch acquisition is bypassed; no UITouch is fabricated.
@MainActor final class PlaybackSliderTests: XCTestCase {
    private func fixture() -> (PlaybackScrubController, PlaybackTrackingSlider, ScrubObserver) {
        let controller = PlaybackScrubController()
        let slider = PlaybackTrackingSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        slider.maximumValue = 100
        slider.value = 20
        let observer = ScrubObserver()
        controller.bind(slider, observer: observer)
        return (controller, slider, observer)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testValueChangedUpdatesDraftButCommitsOnlyOnFinish() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.value = 60
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(observer.drafts.last ?? nil, 60)
        XCTAssertTrue(observer.commits.isEmpty)
        slider.finishScrubbing()
        slider.finishScrubbing()
        XCTAssertEqual(observer.commits, [60])
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.editing, [true, false])
    }

    func testCancelTrackingRejectsFurtherValueAndEndEvents() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.value = 70
        slider.sendActions(for: .valueChanged)
        slider.cancelTracking(with: nil)
        slider.value = 90
        slider.sendActions(for: .valueChanged)
        slider.endTracking(nil, with: nil)
        slider.finishScrubbing()
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertNil(observer.drafts.last ?? nil)
        XCTAssertTrue(observer.commits.isEmpty)
    }

    func testButtonCancellationIsSynchronousBeforeNewSeek() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.value = 70
        slider.sendActions(for: .valueChanged)
        controller.cancel()
        XCTAssertFalse(controller.isEditing(in: slider))
        observer.commit(35) // The button's seek runs after synchronous cancel.
        slider.finishScrubbing()
        XCTAssertEqual(observer.commits, [35])
        XCTAssertNil(observer.drafts.last ?? nil)
    }

    func testDisablingDuringModelUpdateCancelsTrackingAndNotifiesAfterRender() async {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.performModelUpdate { slider.isEnabled = false }
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.editing, [true])
        slider.finishScrubbing()
        await drainMainQueue()
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertNil(observer.drafts.last ?? nil)
        XCTAssertTrue(observer.commits.isEmpty)
        XCTAssertFalse(slider.beginScrubbing())
    }

    func testRemovingSliderFromWindowCancelsWithoutCommitting() async {
        let (controller, slider, observer) = fixture()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.addSubview(slider)
        XCTAssertNotNil(slider.window)
        XCTAssertTrue(slider.beginScrubbing())
        slider.value = 80
        slider.sendActions(for: .valueChanged)
        slider.removeFromSuperview()
        XCTAssertNil(slider.window)
        XCTAssertFalse(controller.isEditing(in: slider))
        slider.finishScrubbing()
        await drainMainQueue()
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertTrue(observer.commits.isEmpty)
    }

    func testDismantleCancelsActiveSession() async {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        controller.detach(slider)
        XCTAssertFalse(controller.isEditing(in: slider))
        slider.finishScrubbing()
        await drainMainQueue()
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertTrue(observer.commits.isEmpty)
    }

    func testOldViewRemovalCannotCancelNewViewsDrag() async {
        let (controller, old, oldObserver) = fixture()
        XCTAssertTrue(old.beginScrubbing())
        let next = PlaybackTrackingSlider(frame: old.frame)
        next.maximumValue = 100
        next.value = 30
        let nextObserver = ScrubObserver()
        controller.bind(next, observer: nextObserver)
        XCTAssertTrue(next.beginScrubbing())
        next.value = 45
        next.sendActions(for: .valueChanged)
        controller.detach(old)
        old.cancelTracking(with: nil)
        old.endTracking(nil, with: nil)
        await drainMainQueue()
        XCTAssertTrue(controller.isEditing(in: next))
        XCTAssertEqual(nextObserver.editing, [true])
        XCTAssertEqual(nextObserver.drafts.last ?? nil, 45)
        XCTAssertTrue(oldObserver.commits.isEmpty)
        next.finishScrubbing()
        XCTAssertEqual(nextObserver.commits, [45])
    }

    func testDeferredCancellationCannotClearAReplacementDrag() async {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.performModelUpdate { slider.isEnabled = false }
        slider.isEnabled = true
        slider.value = 40
        XCTAssertTrue(slider.beginScrubbing())
        await drainMainQueue()
        XCTAssertTrue(controller.isEditing(in: slider))
        XCTAssertEqual(observer.editing.last, true)
        XCTAssertEqual(observer.drafts.last ?? nil, 40)
        slider.finishScrubbing()
        XCTAssertEqual(observer.commits, [40])
    }

    func testVoiceOverAdjustmentsCommitOnceWithoutTouchUp() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable))
        slider.accessibilityIncrement()
        let increased = Double(slider.value)
        XCTAssertGreaterThan(increased, 20)
        XCTAssertEqual(observer.commits, [increased])
        slider.accessibilityDecrement()
        let decreased = Double(slider.value)
        XCTAssertLessThan(decreased, increased)
        XCTAssertEqual(observer.commits, [increased, decreased])
        XCTAssertFalse(controller.isEditing(in: slider))
        slider.finishScrubbing()
        XCTAssertEqual(observer.commits.count, 2)
    }

    func testVoiceOverAdjustmentCancelsOldTouchDraft() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing())
        slider.value = 60
        slider.sendActions(for: .valueChanged)
        slider.accessibilityIncrement()
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.commits, [Double(slider.value)])
        slider.endTracking(nil, with: nil)
        XCTAssertEqual(observer.commits.count, 1)
        slider.isEnabled = false
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        XCTAssertEqual(observer.commits.count, 1)
    }
}
