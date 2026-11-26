import AVFoundation
import UIKit
import XCTest
@testable import NiceVideos

@MainActor final class AfterglowMovieOutputTests: XCTestCase {
    func testOutputPreservesPackedGeometryAndBoundsHighRate8K() throws {
        let source = CGSize(width: 8192, height: 4096)
        let normal = try XCTUnwrap(AfterglowMovieOutput.Format(source: source, sdr: true, fps: 59.94, recovery: false))
        let reduced = try XCTUnwrap(AfterglowMovieOutput.Format(source: source, sdr: false, fps: 59.94, recovery: true))
        XCTAssertEqual(normal.size, CGSize(width: 1920, height: 960))
        XCTAssertEqual(reduced.size, CGSize(width: 1280, height: 640))
        XCTAssertTrue(normal.highRate8K)
        XCTAssertTrue(normal.biPlanar)
        XCTAssertFalse(reduced.biPlanar)
        let small = CGSize(width: 384, height: 192)
        let preview = try XCTUnwrap(AfterglowMovieOutput.Format(source: small, sdr: false, fps: 60, recovery: false))
        XCTAssertEqual(preview.size, small)
        XCTAssertFalse(preview.highRate8K)
        XCTAssertNil(AfterglowMovieOutput.Format(source: .zero, sdr: true, fps: 24, recovery: false))
    }

    func testReplacingInputAndSeekingBeforeMetadataLoadsUsesOnlyNewMovie() async throws {
        let bundle = Bundle(for: Self.self)
        let audio = try XCTUnwrap(bundle.url(forResource: "audio-only", withExtension: "mp4", subdirectory: "Fixtures"))
        let movie = try XCTUnwrap(bundle.url(forResource: "panorama-audio", withExtension: "mp4", subdirectory: "Fixtures"))
        let engine = AppleFilePlaybackEngine(afterglow: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: root.view)
        let diagnostics = PlaybackDiagnostics(bytes: nil)
        engine.diagnostics = diagnostics
        let moving = expectation(description: "Afterglow delivers multiple pictures past the requested seek")
        var frames = 0
        var finished = false
        engine.setVideoFrameHandler { buffer in
            if CVPixelBufferGetWidth(buffer) > 0 { frames += 1 }
        }
        engine.onUpdate = { state in
            if state.phase == .failed { XCTFail(state.error ?? "Unexpected failure") }
            if !finished, state.phase == .playing, state.seconds > 5.3, frames > 2 {
                finished = true
                moving.fulfill()
            }
        }
        try engine.load(fileURL: audio)
        engine.play()
        try engine.load(fileURL: movie)
        engine.seek(to: 5)
        engine.play()
        await fulfillment(of: [moving], timeout: 15)
        let report = diagnostics.report { "" }
        XCTAssertTrue(report.contains("Afterglow packed"), report)
        XCTAssertFalse(report.contains("no decodable video track"), report)
        let layer = try XCTUnwrap(root.view.subviews.first?.layer as? AVPlayerLayer)
        XCTAssertNil(layer.player, "Packed VR playback feeds one output without a second live video layer")
    }

    func testAudioOnlyInputReportsFailureToTheRouter() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-only", withExtension: "mp4", subdirectory: "Fixtures"))
        let engine = AppleFilePlaybackEngine(afterglow: true)
        defer { engine.stop() }
        let failed = expectation(description: "Files without video are rejected before playback starts")
        var firstFailure = true
        engine.setVideoFrameHandler { _ in XCTFail("An audio-only input cannot supply a video frame") }
        engine.onUpdate = { state in
            if state.phase == .failed, firstFailure {
                firstFailure = false
                XCTAssertFalse(state.hasVideo)
                failed.fulfill()
            }
        }
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [failed], timeout: 10)
    }
}
