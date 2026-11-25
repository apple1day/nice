import AVFoundation
import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class AppleFilePlaybackEngineTests: XCTestCase {
    func testAudioOnlyMP4ReportsMissingVideoInsteadOfAdvancingToTheEnd() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-only", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = try await PickedVideoFile.open(url)
        let engine = AppleFilePlaybackEngine(pickedFile: source)
        defer { engine.stop() }
        let failed = expectation(description: "The system player requests a fallback without a video track")
        var failure: PlaybackSnapshot?
        engine.onUpdate = { snapshot in
            if snapshot.phase == .failed && failure == nil {
                failure = snapshot
                failed.fulfill()
            }
        }
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [failed], timeout: 12)
        XCTAssertFalse(try XCTUnwrap(failure).hasVideo)
        XCTAssertFalse(try XCTUnwrap(failure?.error).isEmpty)
    }

    func testSeekingWhenOpenedPausedPreservesIntentAndMovesLayerToReplacementHost() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "offline", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = try await PickedVideoFile.open(url)
        let engine = AppleFilePlaybackEngine(pickedFile: source)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let root = UIViewController()
        window.rootViewController = root
        let firstHost = UIView(frame: window.bounds)
        let secondHost = UIView(frame: window.bounds)
        root.view.addSubview(firstHost)
        root.view.addSubview(secondHost)
        window.makeKeyAndVisible()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: firstHost)
        let layer = try XCTUnwrap(firstHost.subviews.first?.layer as? AVPlayerLayer)
        engine.attach(to: secondHost)
        XCTAssertTrue(firstHost.subviews.isEmpty)
        XCTAssertTrue(secondHost.subviews.first?.layer === layer)

        let preview = expectation(description: "Paused AVPlayerLayer has a frame at the requested position")
        let advanced = expectation(description: "User play resumes the same decoded movie")
        var capturedPreview = false, capturedMoving = false
        engine.onUpdate = { snapshot in
            if snapshot.phase == .paused, snapshot.hasVideo, !capturedPreview,
               let time = layer.player?.currentTime().seconds, abs(time - 1) < 0.1 {
                capturedPreview = true
                preview.fulfill()
            }
            if snapshot.phase == .playing, snapshot.hasVideo, snapshot.seconds > 1.4, !capturedMoving {
                capturedMoving = true
                advanced.fulfill()
            }
        }
        try engine.load(fileURL: url, startAt: 1, paused: true)
        engine.play(waitForPausedFrame: true)
        await fulfillment(of: [preview], timeout: 12)
        XCTAssertEqual(layer.player?.rate, 0)
        engine.play()
        await fulfillment(of: [advanced], timeout: 8)
        engine.stop()
        XCTAssertNil(layer.player)
        XCTAssertTrue(secondHost.subviews.isEmpty)
    }
}
