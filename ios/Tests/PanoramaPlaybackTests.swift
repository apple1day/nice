import AVFoundation
import Metal
import simd
import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class PanoramaPlaybackTests: XCTestCase {
    func testHeadPoseUsesScreenAxesInEachInterfaceOrientation() {
        let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
        let orientations: [(UIInterfaceOrientation, SIMD3<Float>, SIMD3<Float>)] = [
            (.portrait, right, up), (.portraitUpsideDown, -right, -up),
            (.landscapeLeft, up, -right), (.landscapeRight, -up, right)
        ]
        let initial = simd_float3x3(simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3<Float>(1, 2, 3))))
        for (orientation, expectedRight, expectedUp) in orientations {
            let centered = VRHeadTracker.screenToReference(deviceToReference: initial, orientation: orientation)
            XCTAssertLessThan(simd_distance(centered * right, initial * expectedRight), 0.0001)
            XCTAssertLessThan(simd_distance(centered * up, initial * expectedUp), 0.0001)
            XCTAssertLessThan(simd_distance(centered.transpose * (centered * right), right), 0.0001)
        }
    }

    func testPausedPanoramaSamplesExpectedWorldDirectionsAndEyes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal required to verify the projected picture")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = SBSMetalView(frame: .zero)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        // All camera and mode changes below sample a retained, paused frame.
        func draw(_ mode: SBSDisplayMode, yaw: Float, pitch: Float) throws {
            renderer.mode = mode
            renderer.setCamera(yaw: yaw, pitch: pitch, fieldOfView: 80)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            renderer.encodeMovie(pass: pass, command: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status, .completed, String(describing: buffer.error))
        }
        func check(_ x: Int, _ u: Double, _ v: Double, _ eye: Int,
                   file: StaticString = #filePath, line: UInt = #line) {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(x, 64, 1, 1), mipmapLevel: 0)
            }
            XCTAssertEqual(Double(bytes[2]), 32 + 192 * u, accuracy: 5, file: file, line: line)
            XCTAssertEqual(Double(bytes[1]), 32 + 192 * v, accuracy: 5, file: file, line: line)
            XCTAssertEqual(Int(bytes[0]), eye, file: file, line: line)
        }
        renderer.display(try coordinateChart(sideBySide: true))
        try draw(.immersive(.vr180, .sideBySide, headset: false), yaw: 0, pitch: 0)
        check(128, 0.5, 0.5, 36)
        try draw(.immersive(.vr180, .sideBySide, headset: true), yaw: 45, pitch: 45)
        check(64, 0.75, 0.25, 36)
        check(192, 0.75, 0.25, 164)
        try draw(.immersive(.vr180, .sideBySide, headset: true), yaw: 150, pitch: 0)
        for x in [64, 192] {
            var pixel: UInt32 = 0
            target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, 64, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(pixel & 0x00ff_ffff, 0, "Rear hemisphere of a VR180 source")
        }
        renderer.display(try coordinateChart(sideBySide: false))
        try draw(.immersive(.vr360, .topBottom, headset: true), yaw: -120, pitch: -36)
        check(64, 1.0 / 6, 0.70, 36)
        check(192, 1.0 / 6, 0.70, 164)
        try draw(.immersive(.fisheye180, .topBottom, headset: true), yaw: 80, pitch: 70)
        check(64, 0.663, 0.047, 36)
        check(192, 0.663, 0.047, 164)
        try draw(.immersive(.vr360, .mono, headset: false), yaw: 90, pitch: 45)
        // The top quarter of the entire TB frame is the middle of its upper tile.
        check(128, 0.75, 0.5, 36)
    }

    private func coordinateChart(sideBySide: Bool) throws -> CVPixelBuffer {
        let n = 128, width = sideBySide ? 2 * n : n, height = sideBySide ? n : 2 * n
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                           attrs as CFDictionary, &frame), kCVReturnSuccess)
        let pixels = try XCTUnwrap(frame)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * CVPixelBufferGetBytesPerRow(pixels) + 4 * x
                base[p] = (sideBySide ? x : y) < n ? 36 : 164
                base[p + 1] = UInt8(32 + 192 * (y % n) / (n - 1))
                base[p + 2] = UInt8(32 + 192 * (x % n) / (n - 1))
                base[p + 3] = 255
            }
        }
        return pixels
    }

    func testMovingCameraAndChangingEyeDisplayKeepDecodedAudioAndSinglePlayerItem() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "panorama-audio", withExtension: "mp4", subdirectory: "Fixtures"))
        let picked = try await PickedVideoFile.open(url)
        let engine = SBSPlaybackEngine(pickedFile: picked)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 220))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        defer { engine.stop(); window.isHidden = true }
        engine.attach(to: host)
        try engine.load(fileURL: url)
        let layer = try XCTUnwrap(host.drawableView.subviews.first?.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let item = try XCTUnwrap(player.currentItem)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let tap = NICEAudioTapProbe()
        XCTAssertTrue(tap.attach(to: item, track: try XCTUnwrap(tracks.first)))
        host.mode = .immersive(.vr180, .sideBySide, headset: false)
        engine.play()

        let ready = Date().addingTimeInterval(12)
        while Date() < ready && (tap.audibleFrames < 22050 || player.currentTime().seconds < 0.6) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(tap.audibleFrames, 22050, "No decoded non-silent PCM reached the audio mix")
        let output = try XCTUnwrap(item.outputs.first { $0 is AVPlayerItemVideoOutput })
        let renderer = try XCTUnwrap(host.renderer)
        let unexpectedSeek = expectation(forNotification: .AVPlayerItemTimeJumped, object: item)
        unexpectedSeek.isInverted = true
        let stall = expectation(forNotification: .AVPlayerItemPlaybackStalled, object: item)
        stall.isInverted = true
        let start = player.currentTime().seconds
        let pcmBefore = tap.audibleFrames
        for sample in 0..<150 {
            if sample == 70 { host.mode = .immersive(.vr180, .sideBySide, headset: true) }
            renderer.setCamera(yaw: 45 * sin(Float(sample) / 18), pitch: 8 * cos(Float(sample) / 28), fieldOfView: 80)
            try await Task.sleep(nanoseconds: 18_000_000)
        }
        await fulfillment(of: [unexpectedSeek, stall], timeout: 0.1)
        XCTAssertGreaterThan(player.currentTime().seconds - start, 1.5)
        XCTAssertGreaterThan(tap.audibleFrames - pcmBefore, 44100,
                             "Camera movement must continue producing decoded tone, independent of the clock")
        XCTAssertTrue(layer.player === player && player.currentItem === item)
        XCTAssertTrue(host.renderer === renderer && item.outputs.contains(where: { $0 === output }))
    }
}
