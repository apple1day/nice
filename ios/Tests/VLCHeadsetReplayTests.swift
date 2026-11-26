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

        func projectedColors() throws -> [UInt8] {
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
}
