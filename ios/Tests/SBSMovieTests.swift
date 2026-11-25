import CoreVideo
import Metal
import XCTest
@testable import NiceVideos

final class SBSMovieTests: XCTestCase {
    func testHalfAndFullProduceTheSameEyeGeometryForEquivalentMovies() {
        let half = SBSDisplayMode.half.eyeAspect(packedAspect: 1920.0 / 1080)
        let full = SBSDisplayMode.full.eyeAspect(packedAspect: 3840.0 / 1080)
        XCTAssertEqual(half, 16.0 / 9, accuracy: 1e-6)
        XCTAssertEqual(half, full)
        let geometry = SBSMovieGeometry(eyeViewportSize: CGSize(width: 400, height: 390), eyeAspect: half)
        let vertices = geometry.vertices
        let n = SBSMovieGeometry.subdivisions
        XCTAssertEqual(vertices.count, (n + 1) * (n + 1))
        XCTAssertEqual(vertices[n / 2 * (n + 1) + n / 2].position, .zero)
        XCTAssertEqual(vertices.first?.movieUV, SIMD2<Float>(0, 0))
        XCTAssertEqual(vertices.last?.movieUV, SIMD2<Float>(1, 1))
        let upperLeft = vertices[0].position, lowerRight = vertices[vertices.count - 1].position
        XCTAssertEqual(upperLeft.x, -lowerRight.x, accuracy: 1e-5)
        XCTAssertEqual(upperLeft.y, -lowerRight.y, accuracy: 1e-5)
        // A rectangular flat screen constrained to this viewport's width would
        // have x = 1 at either edge. The lens prewarp compresses off-axis points.
        XCTAssertLessThan(lowerRight.x, 1)
        XCTAssertGreaterThan(lowerRight.x, 0.5)
    }

    @MainActor
    func testMetalDrawsDifferentEyesFromOneBGRAFrameAndClearsOnExit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let view = SBSMetalView(frame: .zero)
        let frame = try splitFrame(width: 32, height: 16, left: SIMD3(255, 0, 0), right: SIMD3(0, 255, 0))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 128, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        func render() throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            view.encodeMovie(pass: pass, command: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, String(describing: command.error))
            var bytes = [UInt8](repeating: 0, count: 128 * 64 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: 128 * 4,
                                from: MTLRegionMake2D(0, 0, 128, 64), mipmapLevel: 0)
            }
            return bytes
        }
        func rgb(_ bytes: [UInt8], x: Int, y: Int) -> [UInt8] {
            let i = 4 * (y * 128 + x)
            return [bytes[i + 2], bytes[i + 1], bytes[i]]
        }

        view.mode = .full
        view.display(frame)
        let full = try render()
        XCTAssertEqual(rgb(full, x: 32, y: 32), [255, 0, 0])
        XCTAssertEqual(rgb(full, x: 96, y: 32), [0, 255, 0])
        XCTAssertEqual(rgb(full, x: 32, y: 12), [255, 0, 0])
        view.mode = .half
        let half = try render() // Same paused video buffer, now displayed at twice the eye aspect.
        XCTAssertEqual(rgb(half, x: 32, y: 12), [0, 0, 0])
        XCTAssertEqual(rgb(half, x: 32, y: 32), [255, 0, 0])
        XCTAssertEqual(rgb(half, x: 96, y: 32), [0, 255, 0])
        // Switch the paused movie to ordinary playback. Its full 2:1 frame now
        // fills the 2:1 target, including corners excluded by the lens warp.
        view.mode = .standard
        let ordinary = try render()
        XCTAssertEqual(rgb(ordinary, x: 1, y: 1), [255, 0, 0])
        XCTAssertEqual(rgb(ordinary, x: 126, y: 62), [0, 255, 0])

        // Feed new surfaces with changing colors and aspect. A renderer
        // stuck sampling its first texture fails on the very next frame.
        for i in 0..<8 {
            let red = UInt8(20 + i * 15), blue = UInt8(240 - i * 12)
            let changing = try splitFrame(width: 32, height: 32, left: SIMD3(red, 0, 0), right: SIMD3(0, 0, blue))
            view.display(changing)
            let output = try render()
            XCTAssertEqual(rgb(output, x: 16, y: 32), [0, 0, 0]) // pillarbox for square movies
            XCTAssertEqual(rgb(output, x: 47, y: 32), [red, 0, 0])
            XCTAssertEqual(rgb(output, x: 80, y: 32), [0, 0, blue])
            XCTAssertEqual(rgb(output, x: 110, y: 32), [0, 0, 0])
        }
        view.clear()
        let cleared = try render()
        XCTAssertEqual(rgb(cleared, x: 32, y: 32), [0, 0, 0])
    }

    private func splitFrame(width: Int, height: Int, left: SIMD3<UInt8>, right: SIMD3<UInt8>) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                           attrs as CFDictionary, &image), kCVReturnSuccess)
        let frame = try XCTUnwrap(image)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(frame, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * CVPixelBufferGetBytesPerRow(frame) + x * 4
                let rgb = x < width / 2 ? left : right
                pixels[i] = rgb.z
                pixels[i + 1] = rgb.y
                pixels[i + 2] = rgb.x
                pixels[i + 3] = 255
            }
        }
        return frame
    }
}
