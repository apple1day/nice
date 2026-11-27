import CoreVideo
import Metal
import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class VLCHeadsetReplayTests: XCTestCase {
    func testLocal8KMovieChangesBothEyesAfterEachEOFReplay() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "stereo8k-replay", withExtension: "mp4", subdirectory: "Fixtures"))
        let request = try PlaybackRequest(key: UUID().uuidString, title: "8K SBS", url: url)
        let engine = SBSPlaybackEngine()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = PlaybackModel(request: request, engine: engine, defaults: defaults, manageAudioSession: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        defer {
            model.close()
            window.isHidden = true
            defaults.removePersistentDomain(forName: suite)
        }

        host.configure(mode: .immersive(.vr360, .sideBySide, headset: true), standardOutput: .vlcFrames)
        let renderer = try XCTUnwrap(host.renderer)
        let projectedColors = try makeProjectedColorsProbe(renderer)

        for playthrough in 1...3 {
            var sampledID = renderer.acceptedFrameID
            if playthrough == 1 {
                model.attach(to: host)
            } else {
                XCTAssertEqual(model.phase, .ended)
                model.toggle() // Same action as the play button after natural EOF.
            }
            XCTAssertEqual(engine.currentOutput, .vlcFrames)
            var sawRedBlue = false, sawGreenYellow = false
            let deadline = Date().addingTimeInterval(24)
            while Date() < deadline {
                if renderer.acceptedFrameID > sampledID {
                    sampledID = renderer.acceptedFrameID
                    let colors = try projectedColors()
                    if colors == [4, 1] { sawRedBlue = true }
                    if colors == [2, 6] { sawGreenYellow = true }
                }
                if model.phase == .ended || model.phase == .failed { break }
                if playthrough == 3 && sawRedBlue && sawGreenYellow { break }
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            if playthrough == 1 {
                XCTAssertTrue(model.videoDetails?.contains("8192×2048") == true,
                              "The source track should be reported separately from the scaled VR buffer.")
                XCTAssertTrue(model.videoDetails?.contains("24.00 fps") == true)
            }
            guard sawRedBlue && sawGreenYellow && (playthrough == 3 || model.phase == .ended) else {
                XCTFail("Playthrough \(playthrough): red/blue=\(sawRedBlue) green/yellow=\(sawGreenYellow), " +
                        "phase=\(model.phase) " + (engine.playbackDiagnosticReport() ?? ""))
                return
            }
        }
    }

    // Count only completed draws to the normal full-size drawable during the
    // timed interval. The small eye-color readbacks run beforehand so a GPU
    // readback never stalls the main queue while we're measuring cadence.
    func testSustainedFullHeight8K60VLCToMetalCadence() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "stereo8k60-full", withExtension: "mp4", subdirectory: "Fixtures"))
        // Hold the source, decoder policy, scaler, render size and probe fixed.
        // Only change the vmem output. Report both rates on the same host.
        try await measureFullHeightPlayback(url, color: .packedRGB, fourCC: "BGRA")
        try await measureFullHeightPlayback(url, color: .ycbcr(kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String), fourCC: "420v")
    }

    private func measureFullHeightPlayback(_ url: URL, color: VLCFrameColor, fourCC: String) async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let size = window.bounds.size
        let landscapeSize = CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
        let host = SBSPlaybackView(frame: CGRect(origin: .zero, size: landscapeSize))
        if size.height > size.width { host.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        host.center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        controller.view.addSubview(host)
        host.configure(mode: .immersive(.vr360, .sideBySide, headset: true), standardOutput: .vlcFrames)
        let renderer = try XCTUnwrap(host.renderer)
        let probe = try makeProjectedColorsProbe(renderer)
        let engine = VLCPlaybackEngine(frameHandler: { renderer.display($0) }, preferSmallerPanoramaFrames: true,
                                       frameColor: color)
        defer {
            engine.stop()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        try engine.load(fileURL: url)
        engine.play()
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 12
        var sawRedBlue = false, sawGreenYellow = false
        var sampledID: UInt64 = 0
        while ProcessInfo.processInfo.systemUptime < startupDeadline {
            if renderer.acceptedFrameID > sampledID {
                sampledID = renderer.acceptedFrameID
                let colors = try probe()
                sawRedBlue = sawRedBlue || colors == [4, 1]
                sawGreenYellow = sawGreenYellow || colors == [2, 6]
            }
            if sawRedBlue && sawGreenYellow && renderer.completedVideoFrameCount > 0 { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        guard sawRedBlue, sawGreenYellow, renderer.completedVideoFrameCount > 0 else {
            XCTFail("Full-height 8K60 did not render both color pairs to an active viewer. " + renderer.frameDiagnostics)
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let receivedStart = renderer.receivedFrameID, completedStart = renderer.completedVideoFrameCount
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let completedMiddle = renderer.completedVideoFrameCount
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let received = renderer.receivedFrameID - receivedStart
        let completedEnd = renderer.completedVideoFrameCount
        let completed = completedEnd - completedStart
        let report = String(format: "8K60 VLC/Metal \(fourCC) wall=%.3fs delivered=%llu deliveredFPS=%.2f uniqueGPUFrames=%llu uniqueGPUFPS=%.2f",
                            elapsed, received, Double(received) / elapsed, completed, Double(completed) / elapsed)
            + " " + renderer.frameDiagnostics
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "8K60 immersive VLC cadence \(fourCC)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(renderer.frameDiagnostics.contains("input=1600x800:\(fourCC)"), report)
        XCTAssertGreaterThan(received, 1, report)
        XCTAssertGreaterThan(completedMiddle, completedStart, report)
        XCTAssertGreaterThan(completedEnd, completedMiddle, report)
    }

    private func makeProjectedColorsProbe(_ renderer: SBSMetalView) throws -> () throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        return {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encodeMovie(pass: pass, command: command))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            // Quantize RGB to distinguish the two known colors at each eye center.
            return [16, 48].map { x in
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { bytes in
                    target.getBytes(bytes.baseAddress!, bytesPerRow: 4,
                                    from: MTLRegionMake2D(x, 16, 1, 1), mipmapLevel: 0)
                }
                let red: UInt8 = pixel[2] > 128 ? 4 : 0
                let green: UInt8 = pixel[1] > 128 ? 2 : 0
                let blue: UInt8 = pixel[0] > 128 ? 1 : 0
                return red | green | blue
            }
        }
    }
}
