import UIKit
import XCTest
@testable import NiceVideos

@MainActor final class SBSViewportReadinessTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func visibleWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    func testWaitsForAttachedNonemptyViewportAndStartsOnlyOnce() async {
        let window = visibleWindow()
        defer { window.isHidden = true }
        let host = SBSPlaybackView(frame: .zero)
        var starts = 0
        host.startPlaybackWhenReady { view in
            XCTAssertTrue(view.window === window)
            XCTAssertGreaterThan(view.bounds.width, 0)
            XCTAssertGreaterThan(view.bounds.height, 0)
            starts += 1
        }
        await drainMainQueue()
        XCTAssertEqual(starts, 0)
        window.rootViewController?.view.addSubview(host)
        await drainMainQueue()
        XCTAssertEqual(starts, 0)

        host.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertEqual(starts, 0, "Never start a decoder inside layoutSubviews")
        await drainMainQueue()
        XCTAssertEqual(starts, 1)
        host.frame.size = CGSize(width: 160, height: 240)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        host.startPlaybackWhenReady { _ in XCTFail("Started twice after rotation") }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(starts, 1)
    }

    func testRemovalCancelsQueuedStartAndDismantleDropsTheCallback() async {
        let window = visibleWindow()
        defer { window.isHidden = true }
        let host = SBSPlaybackView(frame: window.bounds)
        var starts = 0
        host.startPlaybackWhenReady { _ in starts += 1 }
        window.rootViewController?.view.addSubview(host)
        host.removeFromSuperview()
        await drainMainQueue()
        XCTAssertEqual(starts, 0)

        window.rootViewController?.view.addSubview(host)
        host.cancelPendingStart()
        await drainMainQueue()
        XCTAssertEqual(starts, 0)
    }
}
