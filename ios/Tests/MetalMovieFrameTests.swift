import CoreVideo
import Metal
import XCTest
@testable import NiceVideos

@MainActor
final class MetalMovieFrameTests: XCTestCase {
    private typealias YCbCr = (y: UInt8, cb: UInt8, cr: UInt8)

    private func stereoFrame(format: OSType, matrix: CFString, left: YCbCr, right: YCbCr) throws -> CVPixelBuffer {
        let width = 32, height = 16
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for x in 0..<width { luma[row + x] = x < width / 2 ? left.y : right.y }
        }
        for y in 0..<(height / 2) {
            let row = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for x in 0..<(width / 2) {
                let pixel = x < width / 4 ? left : right
                chroma[row + x * 2] = pixel.cb
                chroma[row + x * 2 + 1] = pixel.cr
            }
        }
        return buffer
    }

    func testBothEyesUseUpdatedNV12LumaAndChromaIn360HeadsetAndFlatPlayback() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let view = SBSMetalView(frame: .zero)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        func colors() throws -> [[UInt8]] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(view.encodeMovie(pass: pass, command: command))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, String(describing: command.error))
            return [16, 48].map { x in
                var bytes = [UInt8](repeating: 0, count: 4)
                bytes.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(x, 16, 1, 1), mipmapLevel: 0)
                }
                return [bytes[2], bytes[1], bytes[0]]
            }
        }

        let red: [UInt8] = [255, 0, 0], blue: [UInt8] = [0, 0, 255]
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let cases: [(OSType, CFString, YCbCr, YCbCr, [[UInt8]])] = [
            (video, kCVImageBufferYCbCrMatrix_ITU_R_709_2, (63, 102, 240), (32, 240, 118), [red, blue]),
            (video, kCVImageBufferYCbCrMatrix_ITU_R_601_4, (41, 240, 110), (81, 90, 240), [blue, red]),
            (full, kCVImageBufferYCbCrMatrix_ITU_R_709_2, (54, 99, 255), (18, 255, 116), [red, blue]),
            (video, kCVImageBufferYCbCrMatrix_ITU_R_709_2, (16, 128, 128), (235, 128, 128), [[0, 0, 0], [255, 255, 255]])
        ]
        for (format, matrix, left, right, expected) in cases {
            view.display(try stereoFrame(format: format, matrix: matrix, left: left, right: right))
            for mode in [SBSDisplayMode.immersive(.vr360, .sideBySide, headset: true), .standard] {
                view.mode = mode
                let output = try colors()
                for eye in 0..<2 {
                    for channel in 0..<3 {
                        XCTAssertEqual(Double(output[eye][channel]), Double(expected[eye][channel]), accuracy: 3)
                    }
                }
            }
        }
        XCTAssertEqual(view.receivedFrameID, UInt64(cases.count))
        XCTAssertEqual(view.acceptedFrameID, view.receivedFrameID)
        // Offscreen draw success must never count as actual screen presentation.
        XCTAssertEqual(view.presentedFrameID, 0)
        XCTAssertTrue(view.frameDiagnostics.contains("input=32x16:420v"))
        #if targetEnvironment(simulator)
        XCTAssertTrue(view.frameDiagnostics.contains("presentID=NA presentAgeSec=NA presentation=unavailable-on-simulator"))
        #endif
    }
}
