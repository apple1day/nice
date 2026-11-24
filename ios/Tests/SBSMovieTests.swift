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
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &image), kCVReturnSuccess)
        let frame = try XCTUnwrap(image)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(frame, []), kCVReturnSuccess)
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<16 {
            for x in 0..<32 {
                let i = y * CVPixelBufferGetBytesPerRow(frame) + x * 4
                pixels[i] = 0
                pixels[i + 1] = x < 16 ? 0 : 255
                pixels[i + 2] = x < 16 ? 255 : 0
                pixels[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
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
        view.clear()
        let cleared = try render()
        XCTAssertEqual(rgb(cleared, x: 32, y: 32), [0, 0, 0])
    }
}
