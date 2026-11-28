import AVFoundation
import CoreVideo
import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class AppleFilePlaybackEngineTests: XCTestCase {
    func testSystemProjectionUsesTrackGeometryBeforeTheItemHasAPresentationSize() throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        XCTAssertEqual(item.presentationSize, .zero)
        let output = AppleStereoFrameOutput(item: item, recovery: false, preferBiPlanar: { true },
            trackSize: { CGSize(width: 8192, height: 2048) }) { _, _, _ in }
        defer { output.stop() }
        XCTAssertEqual(output.requestDescription, "420v 1920x480")
        let videoOutput = try XCTUnwrap(item.outputs.first as? AVPlayerItemVideoOutput)
        XCTAssertTrue(videoOutput.suppressesPlayerRendering)
    }

    func testFilmRate8KHEVCIsEligibleForTheHardwareTrial() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "stereo8k-replay", withExtension: "mp4", subdirectory: "Fixtures"))
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(rate, 24, accuracy: 0.01)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertTrue(AppleFilePlaybackEngine.isDirectCandidate(try XCTUnwrap(formats.first)))
    }

    func testSystemProjectionFallsBackWhenNeitherPictureNorClockStarts() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "panorama-audio", withExtension: "mp4", subdirectory: "Fixtures"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let engine = AppleFilePlaybackEngine()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: root.view)
        let layer = try XCTUnwrap(root.view.subviews.first?.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let ready = expectation(description: "Native layer has a paused preview")
        engine.onUpdate = { state in
            if state.phase == .paused && state.hasVideo { engine.onUpdate = nil; ready.fulfill() }
        }
        try engine.load(fileURL: url, startAt: 1, paused: true)
        engine.play(waitForPausedFrame: true)
        await fulfillment(of: [ready], timeout: 12)

        let failed = expectation(description: "Foreground startup expires with a stationary clock")
        engine.onUpdate = { state in
            if player.rate != 0 { player.pause() }
            if state.phase == .failed {
                engine.onUpdate = nil
                XCTAssertTrue(state.error?.contains("首帧") == true)
                failed.fulfill()
            }
        }
        let item = try XCTUnwrap(player.currentItem)
        engine.setVideoFrameHandler { _ in XCTFail("A disconnected output cannot supply a picture") }
        let output = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first)
        item.remove(output)
        engine.play()
        // Simulate AVFoundation never starting its timebase even though the
        // user requested play. A media-clock-only watchdog cannot recover.
        player.pause()
        await fulfillment(of: [failed], timeout: 22)
    }

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

    func testStalledProjectedOutputRecoversOnSamePlayingItemAfterItsFirstFrame() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "panorama-audio", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = try await PickedVideoFile.open(url)
        let engine = AppleFilePlaybackEngine(pickedFile: source)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 220))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: controller.view)
        let layer = try XCTUnwrap(controller.view.subviews.last?.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let initial = expectation(description: "Initial output delivers video")
        let restored = expectation(description: "A fresh output delivers video from the same running item")
        var lostOutput: AVPlayerItemVideoOutput?
        var receivedInitial = false, receivedReplacement = false
        engine.setVideoFrameHandler { _ in
            if !receivedInitial {
                receivedInitial = true
                initial.fulfill()
            } else if let lostOutput, !receivedReplacement,
                      player.currentItem?.outputs.contains(where: { $0 is AVPlayerItemVideoOutput && $0 !== lostOutput }) == true {
                receivedReplacement = true
                restored.fulfill()
            }
        }
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [initial], timeout: 12)
        let item = try XCTUnwrap(player.currentItem)
        let original = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first)
        lostOutput = original
        let before = item.currentTime().seconds
        // Lose the frame feed while audio and the item clock keep running.
        // The production watchdog, not the test, must create the replacement.
        item.remove(original)
        await fulfillment(of: [restored], timeout: 24)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertGreaterThan(item.currentTime().seconds, before + 4)
        XCTAssertEqual(player.rate, 1)
        XCTAssertEqual(item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.count, 1)
    }

    func testPausedSeekAndStereoPrerollPreserveTheItemAndPositionAcrossHostChanges() async throws {
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
        let initialItem = try XCTUnwrap(layer.player?.currentItem)
        let pausedStereo = expectation(description: "A newly attached stereo output actually delivers the paused image")
        var stereoFrame: CVPixelBuffer?
        secondHost.isHidden = true
        engine.setVideoFrameHandler { buffer in
            if stereoFrame == nil {
                stereoFrame = buffer
                pausedStereo.fulfill()
            }
        }
        await fulfillment(of: [pausedStereo], timeout: 12)
        let buffer = try XCTUnwrap(stereoFrame)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 1)
        XCTAssertTrue(layer.player?.currentItem === initialItem)
        XCTAssertEqual(layer.player?.rate, 0)
        XCTAssertEqual(initialItem.currentTime().seconds, 1, accuracy: 0.1)
        secondHost.isHidden = false
        engine.setVideoFrameHandler(nil)
        engine.play()
        await fulfillment(of: [advanced], timeout: 8)
        engine.stop()
        XCTAssertNil(layer.player)
        XCTAssertTrue(secondHost.subviews.isEmpty)
    }
}
