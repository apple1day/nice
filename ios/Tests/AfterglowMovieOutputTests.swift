import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import NiceVideos

@MainActor final class AfterglowMovieOutputTests: XCTestCase {
    func testOutputPreservesPackedGeometryAndBounds8KBuffers() throws {
        let source = CGSize(width: 8192, height: 4096)
        let normal = try XCTUnwrap(AfterglowMovieOutput.Format(source: source, sdr: true, recovery: false))
        let reduced = try XCTUnwrap(AfterglowMovieOutput.Format(source: source, sdr: false, recovery: true))
        XCTAssertEqual(normal.size, CGSize(width: 1920, height: 960))
        XCTAssertEqual(reduced.size, CGSize(width: 1280, height: 640))
        XCTAssertTrue(normal.biPlanar)
        XCTAssertFalse(reduced.biPlanar)
        let small = CGSize(width: 384, height: 192)
        let preview = try XCTUnwrap(AfterglowMovieOutput.Format(source: small, sdr: false, recovery: false))
        XCTAssertEqual(preview.size, small)
        XCTAssertNil(AfterglowMovieOutput.Format(source: .zero, sdr: true, recovery: false))
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

    func testPausedOpenThenForwardAndBackwardSeeksDeliverDifferentPackedPictures() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "panorama-audio", withExtension: "mp4", subdirectory: "Fixtures"))
        let engine = AppleFilePlaybackEngine(afterglow: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: root.view)
        let context = CIContext()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var count = 0, blue = -1
        var snapshot = PlaybackSnapshot(phase: .idle)
        engine.onUpdate = { snapshot = $0 }
        engine.setVideoFrameHandler { buffer in
            let image = CIImage(cvPixelBuffer: buffer)
            let bounds = CGRect(x: floor(image.extent.width / 4), y: floor(image.extent.height / 2), width: 1, height: 1)
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
            }
            blue = Int(rgba[2])
            count += 1
        }

        func waitForPicture(at seconds: Double, after previous: Int, colorMatches: (Int) -> Bool) async throws {
            let end = Date().addingTimeInterval(10)
            while Date() < end {
                if count > previous, snapshot.phase == .paused, snapshot.hasVideo, abs(snapshot.seconds - seconds) < 0.15, colorMatches(blue) { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("No paused preview at \(seconds)s: \(count) pictures, blue=\(blue), phase=\(snapshot.phase)")
        }
        try engine.load(fileURL: url, startAt: 0, paused: true)
        engine.play(waitForPausedFrame: true)
        try await waitForPicture(at: 0, after: 0) { $0 >= 0 }
        let first = blue
        var previous = count
        // The source chart alternates the blue channel on each whole second.
        engine.seek(to: 1.25)
        try await waitForPicture(at: 1.25, after: previous) { $0 > first + 15 }
        previous = count
        engine.seek(to: 0.25)
        try await waitForPicture(at: 0.25, after: previous) { abs($0 - first) < 10 }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(snapshot.phase, .paused)
        XCTAssertEqual(snapshot.seconds, 0.25, accuracy: 0.15)
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
