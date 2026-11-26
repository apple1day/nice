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
        let renderer = try XCTUnwrap(host.renderer)
        let pausedFrame = renderer.acceptedFrameID
        XCTAssertGreaterThan(pausedFrame, 0)
        let pausedReport = capture()
        XCTAssertTrue(pausedReport.contains("loadID=1") && pausedReport.contains("buffer=2560x1280"), pausedReport)
        XCTAssertEqual(latest.phase, .paused)
        XCTAssertEqual(latest.seconds, before, accuracy: 0.15)
        host.mode = .immersive(.vr180, .sideBySide, headset: false)
        host.mode = .immersive(.vr360, .sideBySide, headset: true)
        XCTAssertTrue(capture().contains("loadID=1"), capture())
        engine.play()
        let resized = try await waitFor {
            guard latest.phase == .playing, latest.seconds > before + 0.3,
                  renderer.acceptedFrameID >= pausedFrame + 2 else { return false }
            let report = capture()
            return report.contains("loadID=2") && report.contains("buffer=1600x800")
        }
        XCTAssertTrue(resized, engine.playbackDiagnosticReport() ?? "")
        host.mode = .immersive(.vr180, .sideBySide, headset: true)
        XCTAssertTrue(capture().contains("loadID=2"), capture())
    }

    func testAfterglowFailureReturnsToVLCAtTheLatestSeekWithoutRetrying() async throws {
        // VideoLAN accepts this Matroska payload; AVFoundation cannot open it.
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "offline", withExtension: "mkv", subdirectory: "Fixtures"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: source, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        let mode = SBSDisplayMode.immersive(.vr360, .sideBySide, headset: true)
        host.configure(mode: mode, standardOutput: .vlcFrames)
        let engine = SBSPlaybackEngine()
        defer { engine.stop(); window.isHidden = true }
        var snapshot = PlaybackSnapshot(phase: .idle)
        engine.onUpdate = { snapshot = $0 }
        engine.attach(to: host)
        try engine.load(fileURL: file)
        engine.play()
        func waitFor(_ predicate: () -> Bool) async throws -> Bool {
            let end = Date().addingTimeInterval(12)
            while Date() < end && !predicate() { try await Task.sleep(nanoseconds: 40_000_000) }
            return predicate()
        }
        let started = try await waitFor { snapshot.phase == .playing && snapshot.hasVideo }
        XCTAssertTrue(started)
        guard started else { return }
        let renderer = try XCTUnwrap(host.renderer)
        let firstFrame = renderer.acceptedFrameID
        host.configure(mode: mode, standardOutput: .afterglow)
        engine.seek(to: 0.75)
        engine.seek(to: 1.50)
        let restored = try await waitFor {
            engine.currentOutput == .vlcFrames && snapshot.videoOutput == .vlcFrames &&
                snapshot.hasVideo && snapshot.phase == .playing && snapshot.seconds >= 1.45 &&
                renderer.acceptedFrameID > firstFrame
        }
        let report = engine.playbackDiagnosticReport() ?? ""
        XCTAssertTrue(restored, report)
        XCTAssertTrue(report.contains("open loadID=3 start=1.50"), report)
        XCTAssertEqual(report.components(separatedBy: "fallback afterglow -> VLC").count - 1, 1, report)
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
