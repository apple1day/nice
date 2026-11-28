import AVFoundation
import XCTest
@testable import NiceVideos

final class DirectHEVCFrameTests: XCTestCase {
    func testDecodeThatOverlapsDisplayTicksCanImmediatelyStartOneFreshRead() {
        var demand = DirectHEVCReadDemand.idle
        XCTAssertTrue(demand.beginRead())
        for _ in 0..<3 { XCTAssertFalse(demand.beginRead()) }
        XCTAssertTrue(demand.finishRead())
        XCTAssertTrue(demand.beginRead())
        XCTAssertFalse(demand.finishRead())
    }

    func testFilmRateBFramesArriveInSequenceWhenPulledAt30Hz() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "direct-hevc-24", withExtension: "mp4",
                                                           subdirectory: "Fixtures"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = DirectHEVCReader(track: try XCTUnwrap(tracks.first), asset: asset, requireHardware: false)
        defer { reader.close() }
        var times: [Double] = []
        for tick in 0..<60 {
            let clock = Double(tick) / 30
            if let picture = reader.copyPicture(at: clock) {
                let pts = CMSampleBufferGetPresentationTimeStamp(picture).seconds
                XCTAssertLessThanOrEqual(pts, clock + 0.002)
                if let previous = times.last {
                    XCTAssertEqual(pts - previous, 1.0 / 24, accuracy: 0.002)
                }
                times.append(pts)
            }
            if let error = reader.error { throw error }
        }
        XCTAssertGreaterThanOrEqual(times.count, 46, "Missing pictures from the two-second, 48-picture fixture")
    }

    func testRealCompressedHEVCPicturesHaveAdvancingPTSAndMotionInBothEyesAfterSeek() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "direct-hevc", withExtension: "mp4",
                                                           subdirectory: "Fixtures"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = DirectHEVCReader(track: track, asset: asset, requireHardware: false)
        defer { reader.close() }

        func luma(_ sample: CMSampleBuffer) throws -> (Int, Int) {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(image))
            XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRowOfPlane(image, 0) * CVPixelBufferGetHeightOfPlane(image, 0) / 2
            let w = CVPixelBufferGetWidthOfPlane(image, 0)
            return (Int(y[row + w/4]), Int(y[row + 3*w/4]))
        }

        var previous = -1.0
        var images = 0
        var longestGap = 0.0
        var before: (Int, Int)?
        var after: (Int, Int)?
        for i in 0..<54 {
            let clock = Double(i)/30
            let sample = reader.copyPicture(at: clock)
            if let error = reader.error { throw error }
            guard let sample else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            XCTAssertGreaterThan(pts, previous)
            XCTAssertLessThanOrEqual(pts, clock + 0.002)
            if previous >= 0 { longestGap = max(longestGap, pts - previous) }
            previous = pts
            images += 1
            if (0.25...0.75).contains(pts) { before = try luma(sample) }
            if (1.25...1.65).contains(pts) { after = try luma(sample) }
        }
        // The 59.94 fps fixture contains reordered B frames. At 30 pulls
        // per second, bounded lookahead should preserve nearly every tick.
        XCTAssertGreaterThanOrEqual(images, 50)
        XCTAssertLessThanOrEqual(longestGap, 0.051)
        let first = try XCTUnwrap(before)
        let second = try XCTUnwrap(after)
        XCTAssertGreaterThan(second.0 - first.0, 35)
        XCTAssertGreaterThan(second.1 - first.1, 80)

        for (target, expected) in [(1.42, second), (0.63, first)] {
            reader.close()
            var newest: CMSampleBuffer?
            for _ in 0..<12 {
                if let picture = reader.copyPicture(at: target) { newest = picture }
                if let error = reader.error { throw error }
            }
            let sample = try XCTUnwrap(newest)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, target, accuracy: 0.05)
            let eyes = try luma(sample)
            XCTAssertEqual(eyes.0, expected.0, accuracy: 5)
            XCTAssertEqual(eyes.1, expected.1, accuracy: 5)
        }
    }
}
