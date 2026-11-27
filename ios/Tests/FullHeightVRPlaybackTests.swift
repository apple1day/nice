import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class FullHeightVRPlaybackTests: XCTestCase {
    func testAutomatic8K60HeadsetPlaybackAdvancesAfterPauseAndSeek() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "vr8k-main10-hev1", withExtension: "mp4", subdirectory: "Fixtures"))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let previous = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: CGRect(x: 0, y: 0, width: 360, height: 180))
        controller.view.addSubview(host)
        window.makeKeyAndVisible()

        let engine = SBSPlaybackEngine()
        defer {
            engine.stop()
            window.isHidden = true
            previous?.makeKey()
        }
        var snapshot = PlaybackSnapshot(phase: .idle)
        var checkingResume = false
        var resumedTimes: [Double] = []
        engine.onUpdate = { update in
            snapshot = update
            if checkingResume && update.phase == .playing && update.seekable {
                resumedTimes.append(update.seconds)
            }
        }
        host.configure(mode: VRMoviePreferences.mode, standardOutput: .system, decoderPolicy: .automatic)
        let renderer = try XCTUnwrap(host.renderer)
        engine.attach(to: host)
        XCTAssertEqual(engine.currentOutput, .system)
        try engine.load(fileURL: url)
        engine.play()

        // A simulated decoder may support the asset, reject it immediately, or
        // reject the direct hardware session. Require actual GPU frames on the
        // selected route even when the simulator can only use VLC.
        func waitFor(_ condition: () -> Bool) async throws -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !condition() {
                if snapshot.phase == .failed || snapshot.phase == .ended ||
                    ProcessInfo.processInfo.systemUptime >= deadline { return false }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            return true
        }
        let started = try await waitFor {
            snapshot.phase == .playing && snapshot.seekable && snapshot.hasVideo &&
                snapshot.seconds > 0.15 && renderer.completedVideoFrameCount >= 2
        }
        guard started else { return XCTFail(engine.playbackDiagnosticReport() ?? "No initial GPU frames") }

        engine.pause()
        let paused = try await waitFor { snapshot.phase == .paused }
        guard paused else { return XCTFail(engine.playbackDiagnosticReport() ?? "Pause failed") }
        // Keep this within the eight-second fixture and distinct from the current time.
        let target = snapshot.seconds < 2.75 ? 4.0 : 1.5
        engine.seek(to: target)
        let positioned = try await waitFor {
            snapshot.phase == .paused && abs(snapshot.seconds - target) < 0.45
        }
        guard positioned else { return XCTFail(engine.playbackDiagnosticReport() ?? "Paused seek failed") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(snapshot.phase, .paused)
        XCTAssertEqual(snapshot.seconds, target, accuracy: 0.45)

        let framesAtResume = renderer.completedVideoFrameCount
        checkingResume = true
        engine.play()
        let resumed = try await waitFor {
            snapshot.phase == .playing && snapshot.hasVideo &&
                snapshot.seconds >= target + 0.35 && renderer.completedVideoFrameCount >= framesAtResume + 2
        }
        let report = engine.playbackDiagnosticReport() ?? ""
        XCTAssertTrue(resumed, report)
        XCTAssertTrue(resumedTimes.allSatisfy { $0 >= target - 0.45 }, report)
        XCTAssertTrue(engine.currentOutput == .system || engine.currentOutput == .vlcFrames, report)
        let probes = report.components(separatedBy: "probing hardware VideoToolbox").count - 1
        XCTAssertLessThanOrEqual(probes, 1, report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Automatic full-height HEVC playback after pause and seek"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
