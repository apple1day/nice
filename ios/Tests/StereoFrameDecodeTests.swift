import CoreMedia
import CoreVideo
import XCTest
@testable import NiceVideos

@MainActor final class StereoFrameDecodeTests: XCTestCase {
    func testVMEMColorUsesSourceMatrixAndRetainsPackedRGBForExplicitFullRangeOrHDR() throws {
        func hint(_ tags: [String: Any]) throws -> VLCFrameColor {
            var format: CMVideoFormatDescription?
            let result = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC,
                width: 8192, height: 4096, extensions: tags as CFDictionary, formatDescriptionOut: &format)
            XCTAssertEqual(result, noErr)
            return try XCTUnwrap(VLCFrameColor(format: format))
        }
        let matrixKey = kCVImageBufferYCbCrMatrixKey as String
        let rec601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        XCTAssertEqual(try hint([:]).matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(try hint([matrixKey: rec601]).matrix, rec601)
        XCTAssertNil(try hint([kCMFormatDescriptionExtension_FullRangeVideo as String: true]).matrix)
        XCTAssertNil(try hint([kCVImageBufferTransferFunctionKey as String:
                                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String]).matrix)
    }

    func testReducedOutputResumes8KSourceWithSmallerStereoBuffers() async throws {
        try await checkMovingPanorama("stereo8k-replay", width: 1280, height: 320, startAt: 2, reduced: true, biPlanar: true)
    }

    func testFullHeight8K60PanoramaNegotiatesSmallerFramesAndChangesBothEyes() async throws {
        try await checkMovingPanorama("stereo8k60-full", width: 1600, height: 800, startAt: 0, reduced: false, biPlanar: true)
    }

    func testForcedSoftwareDecodesMain10FullHeight8KWithMovingStereoEyes() async throws {
        try await checkMovingPanorama("vr8k-main10-hev1", width: 1600, height: 800, startAt: 0,
                                      reduced: false, biPlanar: true, decoderPolicy: .software)
    }

    private func checkMovingPanorama(_ fixture: String, width expectedWidth: Int, height expectedHeight: Int,
                                     startAt: Double, reduced: Bool, biPlanar: Bool = false,
                                     decoderPolicy: VLCDecoderPolicy = .automatic) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: fixture, withExtension: "mp4", subdirectory: "Fixtures"))
        // Check real stereo motion even when software decoding on the simulator
        // falls behind the audio clock. The chart alternates both eyes at
        // irregular intervals to reduce aliasing in sampled output.
        let software = decoderPolicy == .software
        let requiredTransitions = software ? 3 : 2
        let timeout: TimeInterval = software ? 45 : 15
        let ready = expectation(description: "VLC delivers \(requiredTransitions) stereo color transitions")
        let diagnostics = PlaybackDiagnostics(bytes: nil, log: { _ in })
        diagnostics.setRoute(.vlcFrames, mode: .immersive(.vr360, .sideBySide, headset: true))
        diagnostics.beginInput(at: startAt)
        var clock = 0.0
        var firstClock: Double?
        var previousPair: Int?
        var transitions = 0
        var samples = 0
        var finished = false
        let engine = VLCPlaybackEngine(frameHandler: { frame in
            guard !finished else { return }
            samples += 1
            diagnostics.decodedFrame(frame, pts: nil)
            let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
            XCTAssertEqual(width, expectedWidth)
            XCTAssertEqual(height, expectedHeight)
            guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            // The same moving eye chart must survive the two-plane vmem copy,
            // including independent Y/UV strides and interleaved Cb/Cr ordering.
            let pair: Int
            if biPlanar {
                guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      CVPixelBufferGetPlaneCount(frame) == 2,
                      let y = CVPixelBufferGetBaseAddressOfPlane(frame, 0),
                      let uv = CVPixelBufferGetBaseAddressOfPlane(frame, 1) else {
                    XCTFail("Expected VLC to deliver an NV12 IOSurface"); return
                }
                XCTAssertEqual(CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                               kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
                let luma = y.advanced(by: height / 2 * CVPixelBufferGetBytesPerRowOfPlane(frame, 0))
                    .assumingMemoryBound(to: UInt8.self)
                let chroma = uv.advanced(by: height / 4 * CVPixelBufferGetBytesPerRowOfPlane(frame, 1))
                    .assumingMemoryBound(to: UInt8.self)
                let left = width / 4, right = 3 * width / 4
                // Red/blue, then lime/yellow in the fixture (limited-range YUV).
                if luma[left] < 110 && luma[right] < 90 && chroma[left + 1] > 175 && chroma[right] > 175 {
                    pair = 0
                } else if luma[left] > 115 && luma[right] > 170 && chroma[left + 1] < 95 && chroma[right] < 90 {
                    pair = 1
                } else { return }
            } else {
                guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
                      let base = CVPixelBufferGetBaseAddress(frame) else { XCTFail("Expected packed BGRA"); return }
                let row = base.advanced(by: (height / 2) * CVPixelBufferGetBytesPerRow(frame)).assumingMemoryBound(to: UInt8.self)
                let left = (width / 4) * 4, right = (3 * width / 4) * 4
                if row[left + 2] > 180 && row[left + 1] < 70 && row[right] > 180 {
                    pair = 0
                } else if row[left + 1] > 180 && row[left + 2] < 70 && row[right + 2] > 180 && row[right + 1] > 180 {
                    pair = 1
                } else { return }
            }
            if let previousPair, pair != previousPair { transitions += 1 }
            previousPair = pair
            if firstClock == nil { firstClock = clock }
            if transitions >= requiredTransitions, let firstClock, clock >= max(startAt, firstClock) + 0.4 {
                finished = true
                ready.fulfill()
            }
        }, reducedFrameOutput: reduced, preferSmallerPanoramaFrames: true, decoderPolicy: decoderPolicy)
        engine.diagnostics = diagnostics
        engine.onUpdate = { snapshot in
            clock = snapshot.seconds
            diagnostics.observe(snapshot) { "" }
        }
        defer { engine.stop() }
        try engine.load(fileURL: url, startAt: startAt, paused: false)
        engine.play()
        await fulfillment(of: [ready], timeout: timeout)
        let report = diagnostics.report { "" }
        let measurements = "Eye-pair changes=\(transitions)/\(requiredTransitions), sampled frames=\(samples), media clock=\(clock)."
        XCTAssertTrue(finished, measurements + " " + report)
        if software {
            print("Forced software HEVC motion: " + measurements)
            XCTAssertTrue(report.contains("decoderPolicy=software observedVideoDecoder=avcodec"), report)
        }
    }

    func testSBSFramePreservesBothEyesInMetalCompatibleBGRA() async throws {
        try await checkStereoOutput(picked: false)
    }

    func testVLCContinuesProducingWhileFourOutputSurfacesAreRetained() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures"))
        let ready = expectation(description: "VLC delivers successive replacements with four outstanding surfaces")
        var retained: [CVPixelBuffer] = []
        var deliveries = 0
        let engine = VLCPlaybackEngine(frameHandler: { frame in
            guard deliveries < 8 else { return }
            // Model the two in-flight GPU commands, renderer and delivery slot
            // by releasing the oldest surface only once its replacement arrives.
            XCTAssertFalse(retained.contains { $0 === frame })
            if retained.count == 4 { retained.removeFirst() }
            retained.append(frame)
            deliveries += 1
            if deliveries == 8 { ready.fulfill() }
        }, preferSmallerPanoramaFrames: true)
        defer { engine.stop() }
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(deliveries, 8)
    }

    func testPickedSBSFramePreservesVisibleGeometryAndBothEyes() async throws {
        try await checkStereoOutput(picked: true)
    }

    func testTruncatedPickedFileReportsIncompleteDataToThePlayer() async throws {
        let original = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(contentsOf: original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try await PickedVideoFile.open(url)
        // Keep the same inode but take away its bytes after successful opening.
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 0)
        try writer.close()
        let engine = SBSPlaybackEngine(pickedFile: file)
        defer { engine.stop() }
        try engine.load(fileURL: file.url)
        let failed = expectation(description: "A real premature EOF becomes a playback failure")
        var failure: PlaybackSnapshot?
        engine.onUpdate = { state in
            guard state.phase == .failed, failure == nil else { return }
            failure = state
            failed.fulfill()
        }
        engine.play()
        await fulfillment(of: [failed], timeout: 15)
        let message = try XCTUnwrap(failure?.error)
        XCTAssertTrue(message.contains("不完整"), message)
        XCTAssertTrue(message.contains("\(NSCocoaErrorDomain) \(CocoaError.Code.fileReadCorruptFile.rawValue)"), message)
    }

    private func checkStereoOutput(picked: Bool) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures"))
        let file: PickedVideoFile?
        if picked { file = try await PickedVideoFile.open(url) } else { file = nil }
        let decoded = expectation(description: "VLC delivers both eyes in one BGRA frame")
        var firstFrame: CVPixelBuffer?
        let engine = VLCPlaybackEngine(frameHandler: { frame in
            XCTAssertTrue(Thread.isMainThread)
            guard firstFrame == nil else { return }
            firstFrame = frame
            decoded.fulfill()
        }, pickedFile: file)
        defer { engine.stop() }
        try engine.load(fileURL: file?.url ?? url)
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
