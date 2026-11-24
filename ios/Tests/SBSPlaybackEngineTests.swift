import XCTest
import UIKit
@testable import NiceVideos

@MainActor
final class SBSPlaybackEngineTests: XCTestCase {
    func testPausedMKVReopensAtItsPositionAndResumesAfterLeavingVR() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "offline", withExtension: "mkv", subdirectory: "Fixtures"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()

        let engine = SBSPlaybackEngine()
        var latest = PlaybackSnapshot(phase: .idle)
        let ready = expectation(description: "MKV running on the native drawable")
        var reachedTime = false
        engine.onUpdate = { state in
            latest = state
            if !reachedTime && state.phase == .playing && state.seconds >= 0.45 {
                reachedTime = true
                ready.fulfill()
            }
        }
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: host)
        try engine.load(fileURL: file)
        engine.play()
        await fulfillment(of: [ready], timeout: 15)

        engine.pause()
        let before = latest.seconds
        for mode in [SBSDisplayMode.half, .standard] {
            let paused = expectation(description: "Reopened MKV stays paused with a valid video output in \(mode)")
            var pausedOnce = false
            engine.onUpdate = { state in
                latest = state
                if !pausedOnce && state.phase == .paused && state.seekable && state.hasVideo {
                    pausedOnce = true
                    paused.fulfill()
                }
            }
            host.mode = mode
            await fulfillment(of: [paused], timeout: 15)
            XCTAssertTrue(pausedOnce, "mode=\(mode) latest=\(latest)")
            XCTAssertEqual(latest.seconds, before, accuracy: 0.45)
            let pausedAt = latest.seconds
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(latest.phase, .paused)
            XCTAssertEqual(latest.seconds, pausedAt, accuracy: 0.15)
            if mode == .half {
                let renderer = try XCTUnwrap(host.renderer)
                host.mode = .full
                XCTAssertTrue(renderer === host.renderer)
            }
        }

        let resumed = expectation(description: "Audio/video clock progresses again on the same MKV")
        var resumedOnce = false
        engine.onUpdate = { state in
            if !resumedOnce && state.phase == .playing && state.seconds >= before + 0.25 {
                resumedOnce = true
                resumed.fulfill()
            }
        }
        engine.play()
        await fulfillment(of: [resumed], timeout: 15)
    }
}
