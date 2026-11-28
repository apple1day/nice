import CoreVideo
import XCTest
@testable import NiceVideos

final class PlaybackDiagnosticsTests: XCTestCase {
    func testClockCanAdvanceIndependentlyOfCopiedAndPresentedFrames() throws {
        var t = 0.0
        var messages: [String] = []
        let trace = PlaybackDiagnostics(bytes: 5_200_000_000, now: { t }, log: { messages.append($0) })
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        trace.setRoute(.system, mode: .immersive(.vr360, .sideBySide, headset: true))
        trace.decodedFrame(try XCTUnwrap(pixel), pts: 1)
        var probes = 0
        func sample(_ time: Double) {
            t = time
            trace.observe(PlaybackSnapshot(phase: .playing, seconds: time, duration: 100, hasVideo: true)) {
                probes += 1
                return "presented=1"
            }
        }
        sample(1)
        for n in 1...20 { sample(1 + Double(n) / 10) }
        XCTAssertEqual(probes, 1, "A player clock update must not poll Metal or write to the log each frame")
        sample(9)
        let copied = trace.report { "presented=1" }
        XCTAssertEqual(probes, 2)
        XCTAssertTrue(copied.contains("fileBytes=5200000000"))
        XCTAssertTrue(copied.contains("media=9.00/100.00"))
        XCTAssertTrue(copied.contains("copied=1"))
        XCTAssertTrue(copied.contains("framePTS=1.00"))
        XCTAssertTrue(copied.contains("copyAge=9.00s"))
        XCTAssertTrue(copied.contains("buffer=8x4 fourcc=BGRA"))
        XCTAssertTrue(copied.contains("presented=1"))
        XCTAssertTrue(messages.contains(where: { $0.contains("media=9.00/100.00") }))
    }

    func testReplayOnSameOutputStartsNewFrameCountsAndKeepsPreviousSamples() throws {
        let trace = PlaybackDiagnostics(bytes: nil, now: { 20 }, log: { _ in })
        trace.setRoute(.vlcFrames, mode: .immersive(.vr360, .sideBySide, headset: true))
        trace.beginInput(at: 0, differentFile: true)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        trace.decodedFrame(try XCTUnwrap(pixel), pts: nil)
        trace.observe(PlaybackSnapshot(phase: .ended, seconds: 8, duration: 8, hasVideo: true)) { "presentID=91" }

        trace.beginInput(at: 0)
        let lines = trace.report { "presentID=91" }.split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.contains("loadID=1") && $0.contains("copied=1") })
        let capture = try XCTUnwrap(lines.last)
        XCTAssertTrue(capture.contains("loadID=2"))
        XCTAssertTrue(capture.contains("videoReady=0"))
        XCTAssertTrue(capture.contains("copied=0 copyAge=-s"))
    }

    func testCaptureIncludesFallbackReasonOmitsPrivateErrorsAndBoundsHistory() {
        var t = 0.0
        let trace = PlaybackDiagnostics(bytes: nil, now: { t }, log: { _ in })
        trace.setRoute(.system, mode: .half)
        trace.appleStatus("avError=AVFoundationErrorDomain:-11819")
        trace.observe(PlaybackSnapshot(phase: .failed, error: "bad URL: /private/folder/private-movie.mp4")) { "metal=inactive" }
        trace.event("fallback system -> VLC")
        trace.setRoute(.vlcFrames, mode: .half)
        trace.vlcStatus("lost=2")
        let report = trace.report { "presented=0" }
        XCTAssertTrue(report.contains("avError=AVFoundationErrorDomain:-11819"))
        XCTAssertTrue(report.contains("fallback system -> VLC"))
        XCTAssertTrue(report.contains("lost=2"))
        XCTAssertFalse(report.contains("private"))
        for i in 0..<150 {
            t += 5
            trace.observe(PlaybackSnapshot(phase: .playing, seconds: Double(i))) { "metal=inactive" }
        }
        let lines = trace.report { "metal=inactive" }.split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 40)
        XCTAssertTrue(lines.last?.contains("media=149.00/0.00") == true)
        XCTAssertTrue(lines[1].contains("session="))
    }
}
