import XCTest
import UIKit
@testable import NiceVideos

@MainActor
final class SBSPlaybackEngineTests: XCTestCase {
    func testRunningVLCMemoryOutputRenegotiatesFullHeight8KOnlyWhenEnteringPanorama() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "stereo8k60-full", withExtension: "mp4", subdirectory: "Fixtures"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        host.configure(mode: .standard, standardOutput: .vlcFrames)
        let engine = SBSPlaybackEngine()
        var latest = PlaybackSnapshot(phase: .idle)
        engine.onUpdate = { latest = $0 }
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: host)
        try engine.load(fileURL: file)
        engine.play()

        func waitFor(_ predicate: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 80_000_000) }
            return predicate()
        }
        func capture() -> String { engine.playbackDiagnosticReport()?.components(separatedBy: "\n").last ?? "" }
        let ordinary = try await waitFor {
            latest.seekable && latest.seconds > 0.25 && capture().contains("buffer=2560x1280")
        }
        XCTAssertTrue(ordinary, capture())
        guard ordinary else { return }
        engine.pause()
        let paused = try await waitFor { latest.phase == .paused }
        XCTAssertTrue(paused)
        let before = latest.seconds
        host.mode = .immersive(.vr360, .sideBySide, headset: true)
        let resized = try await waitFor {
            latest.phase == .paused && capture().contains("loadID=2") && capture().contains("buffer=1600x800")
        }
        XCTAssertTrue(resized, engine.playbackDiagnosticReport() ?? "")
        XCTAssertEqual(latest.seconds, before, accuracy: 0.5)
        host.mode = .immersive(.vr180, .sideBySide, headset: false)
        host.mode = .immersive(.vr360, .sideBySide, headset: true)
        XCTAssertTrue(capture().contains("loadID=2"), capture())
        engine.play()
        let resumed = try await waitFor { latest.phase == .playing && latest.seconds > before + 0.3 }
        XCTAssertTrue(resumed, capture())
        XCTAssertTrue(capture().contains("loadID=2"), capture())
    }

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
