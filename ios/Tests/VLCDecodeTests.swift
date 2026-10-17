import XCTest
import UIKit
@testable import NiceVideos

// These tests exercise the REAL pinned VLC engine and real local MP4/MKV files.
// They are not a substitute for physical-device codecs/audio/rotation/flight-mode tests.
@MainActor final class VLCDecodeTests: XCTestCase {
    func testRejectsRemoteSourceAtEngineBoundary() {
        let engine = VLCPlaybackEngine()
        XCTAssertThrowsError(try engine.load(fileURL: URL(string: "http://127.0.0.1:9/api/stream/a.mp4")!))
        engine.stop()
    }
    func testDecodeLocalMP4WithVideoFrames() async throws { try await decode(ext: "mp4") }
    func testDecodeLocalMKVWithVideoFrames() async throws { try await decode(ext: "mkv") }

    func testRepeatedOpenStopAndReleaseKeepsMainQueueResponsive() async throws {
        let file = try XCTUnwrap(Bundle(for: VLCDecodeTests.self).url(
            forResource: "offline", withExtension: "mp4", subdirectory: "Fixtures"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer { window.isHidden = true }

        // Exercise both opening-time teardown and teardown after actual output.
        // Dropping the engine is deliberate: retaining it until the test ends
        // would miss the native destruction path reached by switching videos.
        for iteration in 0..<4 {
            let surface = UIView(frame: controller.view.bounds)
            controller.view.addSubview(surface)
            var engine: VLCPlaybackEngine? = VLCPlaybackEngine()
            weak var retiredEngine = engine
            let ready = expectation(description: "opened clip \(iteration)")
            var readyReported = false
            engine?.onUpdate = { snapshot in
                guard !readyReported else { return }
                if snapshot.phase == .failed {
                    XCTFail(snapshot.error ?? "VLC failed to open the local fixture")
                    readyReported = true
                    ready.fulfill()
                } else if snapshot.hasVideo && snapshot.seconds >= 0.2 {
                    readyReported = true
                    ready.fulfill()
                }
            }
            engine?.attach(to: surface)
            try engine?.load(fileURL: file)
            engine?.play()
            if iteration.isMultiple(of: 2) {
                readyReported = true
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 20)

            let started = ProcessInfo.processInfo.systemUptime
            engine?.stop()
            engine?.stop()
            engine = nil
            surface.removeFromSuperview()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertLessThan(elapsed, 1.0, "Native teardown must not wait on the UI thread")
            XCTAssertNil(retiredEngine, "Late native events must not retain the closed engine")

            let responsive = expectation(description: "main queue after release \(iteration)")
            DispatchQueue.main.async { responsive.fulfill() }
            await fulfillment(of: [responsive], timeout: 2)
        }
    }

    private func decode(ext: String) async throws {
        let file = try XCTUnwrap(Bundle(for: VLCDecodeTests.self).url(
            forResource: "offline", withExtension: ext, subdirectory: "Fixtures"))
        XCTAssertTrue(file.isFileURL)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let engine = VLCPlaybackEngine()
        defer { engine.stop(); window.isHidden = true }
        let ready = expectation(description: "VLC decoded local \(ext) video")
        var finished = false
        var decoded = false
        var failure: String?
        engine.onUpdate = { snapshot in
            guard !finished else { return }
            if snapshot.phase == .failed {
                failure = snapshot.error
                finished = true
                ready.fulfill()
            } else if snapshot.hasVideo && snapshot.seconds >= 0.2 {
                decoded = true
                finished = true
                ready.fulfill()
            }
        }
        engine.attach(to: controller.view)
        try engine.load(fileURL: file)
        engine.play()
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertTrue(decoded, failure ?? "VLC did not report local video output and advancing time")
    }
}
