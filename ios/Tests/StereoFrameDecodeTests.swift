import CoreVideo
import XCTest
@testable import NiceVideos

@MainActor final class StereoFrameDecodeTests: XCTestCase {
    func testSBSFramePreservesBothEyesInMetalCompatibleBGRA() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures"))
        let decoded = expectation(description: "VLC delivers both eyes in one BGRA frame")
        var firstFrame: CVPixelBuffer?
        let engine = VLCPlaybackEngine(frameHandler: { frame in
            XCTAssertTrue(Thread.isMainThread)
            guard firstFrame == nil else { return }
            firstFrame = frame
            decoded.fulfill()
        })
        defer { engine.stop() }
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [decoded], timeout: 15)
        let frame = try XCTUnwrap(firstFrame)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame))
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        XCTAssertEqual(width, 256)
        XCTAssertEqual(height, 96)
        let display = CVImageBufferGetDisplaySize(frame)
        XCTAssertEqual(display.width / display.height, 4, accuracy: 0.01) // 256:96, with 3:2 pixels
        guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else {
            return XCTFail("Could not inspect the decoded eye colors")
        }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        for y in [0, height / 2, height - 1] {
            let row = y * CVPixelBufferGetBytesPerRow(frame)
            let left = row + (width / 4) * 4
            let right = row + (3 * width / 4) * 4
            XCTAssertGreaterThan(bytes[left + 2], 180) // red left eye
            XCTAssertLessThan(bytes[left], 60)
            XCTAssertGreaterThan(bytes[right], 180) // blue right eye
            XCTAssertLessThan(bytes[right + 2], 60)
        }
    }
}
