import XCTest
import UIKit
import SwiftUI
@testable import NiceVideos

private final class ScrubObserver: PlaybackScrubObserver {
    var drafts: [Double?] = []
    var editing: [Bool] = []
    var commits: [Double] = []
    func draftChanged(_ seconds: Double?) { drafts.append(seconds) }
    func editingChanged(_ value: Bool) { editing.append(value) }
    func commit(_ seconds: Double) { commits.append(seconds) }
}

@MainActor private struct PlaybackSliderTestHost: View {
    let seconds: Double
    let controller: PlaybackScrubController
    let observer: ScrubObserver

    var body: some View {
        PlaybackSlider(seconds: seconds, duration: 100, isEnabled: true,
                       controller: controller,
                       onDraftChanged: observer.draftChanged,
                       onEditingChanged: observer.editingChanged,
                       onCommit: observer.commit)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .padding(.horizontal, 16)
            .frame(width: 320, height: 160)
    }
}

// Unit tests drive the control's coordinate, target-action and lifecycle seams.
// Hosting tests check SwiftUI layout/hit testing; the UI test target separately
// verifies OS touch acquisition, dragging and release. No UITouch is fabricated.
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

    private func findSlider(in view: UIView) -> PlaybackTrackingSlider? {
        if let slider = view as? PlaybackTrackingSlider { return slider }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) { return slider }
        }
        return nil
    }

    private func hostedFixture(controller: PlaybackScrubController, observer: ScrubObserver) async throws
        -> (UIWindow, UIHostingController<PlaybackSliderTestHost>, PlaybackTrackingSlider) {
        let host = UIHostingController(rootView: PlaybackSliderTestHost(
            seconds: 20, controller: controller, observer: observer))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        await drainMainQueue()
        host.view.layoutIfNeeded()
        let slider = try XCTUnwrap(findSlider(in: host.view))
        return (window, host, slider)
    }

    func testTrackPressAwayFromThumbDragsBothWaysAndClampsAtEdges() {
        let (controller, slider, observer) = fixture()
        // The thumb starts at 20. A press near the top of the 44pt surface
        // must immediately acquire the track at 80, without touching the thumb.
        XCTAssertTrue(slider.beginScrubbing(at: CGPoint(x: 234, y: 1)))
        XCTAssertEqual(slider.value, 80)
        XCTAssertEqual(observer.drafts.last ?? nil, 80)
        XCTAssertTrue(controller.isEditing(in: slider))

        XCTAssertTrue(slider.continueScrubbing(at: CGPoint(x: 330, y: 43)))
        XCTAssertEqual(slider.value, 100)
        XCTAssertTrue(slider.continueScrubbing(at: CGPoint(x: 66, y: 43)))
        XCTAssertEqual(slider.value, 20)
        XCTAssertTrue(slider.continueScrubbing(at: CGPoint(x: -30, y: 60)))
        XCTAssertEqual(slider.value, 0)
        XCTAssertTrue(observer.commits.isEmpty)

        // The release coordinate is authoritative even without another move.
        slider.finishScrubbing(at: CGPoint(x: 150, y: 43))
        slider.finishScrubbing(at: CGPoint(x: 290, y: 43))
        XCTAssertEqual(observer.commits, [50])
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertNil(observer.drafts.last ?? nil)
        XCTAssertFalse(controller.isEditing(in: slider))
    }

    func testCancelledCoordinateDragRejectsLateMoveAndRelease() {
        let (controller, slider, observer) = fixture()
        XCTAssertTrue(slider.beginScrubbing(at: CGPoint(x: 234, y: 22)))
        controller.cancel()

        XCTAssertFalse(slider.continueScrubbing(at: CGPoint(x: 290, y: 22)))
        slider.finishScrubbing(at: CGPoint(x: 66, y: 22))
        XCTAssertEqual(slider.value, 80)
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.editing, [true, false])
        XCTAssertNil(observer.drafts.last ?? nil)
        XCTAssertTrue(observer.commits.isEmpty)
    }

    func testDisabledOrInvalidGeometryCannotStartCoordinateDrag() {
        let (controller, slider, observer) = fixture()
        slider.isEnabled = false
        XCTAssertFalse(slider.beginScrubbing(at: CGPoint(x: 150, y: 22)))
        slider.isEnabled = true

        for size in [CGSize(width: 20, height: 44), CGSize(width: 300, height: 0)] {
            slider.bounds.size = size
            XCTAssertFalse(slider.beginScrubbing())
            XCTAssertFalse(slider.beginScrubbing(at: CGPoint(x: size.width / 2, y: size.height / 2)))
        }
        slider.bounds.size = CGSize(width: 300, height: 44)
        XCTAssertFalse(slider.beginScrubbing(at: CGPoint(x: CGFloat.nan, y: 22)))
        XCTAssertFalse(slider.beginScrubbing(at: CGPoint(x: 150, y: CGFloat.infinity)))
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertTrue(observer.editing.isEmpty)
        XCTAssertTrue(observer.commits.isEmpty)
    }

    func testSwiftUIHostingProvidesFullWidthAndFortyFourPointHitSurface() async throws {
        let controller = PlaybackScrubController()
        let observer = ScrubObserver()
        let (window, host, slider) = try await hostedFixture(controller: controller, observer: observer)
        defer { window.isHidden = true }

        XCTAssertGreaterThanOrEqual(slider.bounds.width, 280)
        XCTAssertEqual(slider.bounds.height, 44, accuracy: 0.5)
        for point in [CGPoint(x: 20, y: 1), CGPoint(x: slider.bounds.width - 20, y: 43)] {
            let hostPoint = slider.convert(point, to: host.view)
            XCTAssertTrue(host.view.hitTest(hostPoint, with: nil) === slider,
                          "The full progress row must receive touches, including above and below the thumb.")
        }
    }

    func testHostedPlaybackTimeUpdatesPreserveDragAndResumeAfterRelease() async throws {
        let controller = PlaybackScrubController()
        let observer = ScrubObserver()
        let (window, host, slider) = try await hostedFixture(controller: controller, observer: observer)
        defer { window.isHidden = true }
        let midpoint = CGPoint(x: slider.bounds.midX, y: slider.bounds.midY)
        XCTAssertTrue(slider.beginScrubbing(at: midpoint))
        XCTAssertEqual(slider.value, 50)

        host.rootView = PlaybackSliderTestHost(seconds: 27, controller: controller, observer: observer)
        host.view.layoutIfNeeded()
        await drainMainQueue()
        host.view.layoutIfNeeded()
        XCTAssertTrue(findSlider(in: host.view) === slider)
        XCTAssertTrue(controller.isEditing(in: slider))
        XCTAssertEqual(slider.value, 50)
        XCTAssertEqual(observer.drafts.last ?? nil, 50)
        XCTAssertTrue(observer.commits.isEmpty)

        slider.finishScrubbing(at: midpoint)
        XCTAssertEqual(observer.commits, [50])
        host.rootView = PlaybackSliderTestHost(seconds: 56, controller: controller, observer: observer)
        host.view.layoutIfNeeded()
        await drainMainQueue()
        host.view.layoutIfNeeded()
        XCTAssertEqual(slider.value, 56)
        XCTAssertFalse(controller.isEditing(in: slider))
        XCTAssertEqual(observer.commits, [50])
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
        XCTAssertTrue(slider.isAccessibilityElement)
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable))
        slider.accessibilityIncrement()
        let increased = Double(slider.value)
        XCTAssertEqual(increased, 35)
        XCTAssertEqual(observer.commits, [increased])
        slider.accessibilityDecrement()
        let decreased = Double(slider.value)
        XCTAssertEqual(decreased, 20)
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
        XCTAssertEqual(slider.value, 75)
        XCTAssertEqual(observer.commits, [Double(slider.value)])
        slider.endTracking(nil, with: nil)
        XCTAssertEqual(observer.commits.count, 1)
        slider.isEnabled = false
        XCTAssertTrue(slider.accessibilityTraits.contains(.notEnabled))
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        XCTAssertEqual(observer.commits.count, 1)
    }

    func testVoiceOverClampsAtBothEndsWithoutRepeatingBoundarySeeks() {
        let (controller, slider, observer) = fixture()
        slider.value = 97
        slider.accessibilityIncrement()
        slider.accessibilityIncrement()
        XCTAssertEqual(slider.value, 100)
        XCTAssertEqual(observer.commits, [100])
        slider.value = 3
        slider.accessibilityDecrement()
        slider.accessibilityDecrement()
        XCTAssertEqual(slider.value, 0)
        XCTAssertEqual(observer.commits, [100, 0])
        XCTAssertFalse(controller.isEditing(in: slider))
    }

    func testVoiceOverStepRemainsFifteenSecondsForLongMedia() {
        let (controller, slider, observer) = fixture()
        slider.maximumValue = 36_000
        slider.value = 1_000
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        XCTAssertEqual(observer.commits, [1_015, 1_000])
        XCTAssertFalse(controller.isEditing(in: slider))
    }

    func testVoiceOverHandlesMediaShorterThanOneStepAndDisabledRecovery() {
        let (controller, slider, observer) = fixture()
        slider.maximumValue = 2.5
        slider.value = 1
        slider.accessibilityIncrement()
        XCTAssertEqual(observer.commits, [2.5])
        slider.isEnabled = false
        slider.accessibilityDecrement()
        XCTAssertEqual(observer.commits, [2.5])
        slider.isEnabled = true
        XCTAssertFalse(slider.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable))
        slider.accessibilityDecrement()
        XCTAssertEqual(observer.commits, [2.5, 0])
        XCTAssertFalse(controller.isEditing(in: slider))
    }
}
