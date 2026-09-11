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
