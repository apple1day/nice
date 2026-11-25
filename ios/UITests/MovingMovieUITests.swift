import UIKit
import XCTest

@MainActor
final class MovingMovieUITests: XCTestCase {
    func testPickedMovieActuallyChangesPixelsInStandardAndFullSBS() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launchMovie("moving-stereo", fileExtension: "mp4")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }

        let surface = app.descendants(matching: .any)["playbackSurfaceToggle"]
        try require(surface.waitForExistence(timeout: 15), app.debugDescription)
        try assertChangingEyes(in: app, surface: surface, mode: "ordinary portrait")
        revealControls(surface)
        // Move sufficiently far into the clip that restarting at zero on a
        // format change is unambiguous even on a slow simulator.
        app.buttons["前进15秒"].tap()
        try assertChangingEyes(in: app, surface: surface, mode: "after seek")
        revealControls(surface)
        let elapsed = app.staticTexts["playbackElapsedTime"]
        let before = try seconds(elapsed)
        try require(before >= 15, "Fast-forward did not advance to 15 seconds. Elapsed: \(before)")

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        try require(XCTWaiter.wait(for: [landscape], timeout: 8) == .completed, "Landscape rotation timed out")
        revealControls(surface)
        let formats = app.buttons["videoFormatButton"]
        formats.tap()
        app.buttons["全宽 SBS（Full SBS）"].tap()
        try assertChangingEyes(in: app, surface: surface, mode: "full SBS")
        revealControls(surface)
        try require(formats.value as? String == "全宽 SBS", "Expected full SBS")
        try checkPosition(elapsed, after: before)

        formats.tap()
        app.buttons["退出 VR，普通播放"].tap()
        try assertChangingEyes(in: app, surface: surface, mode: "back to normal")
        revealControls(surface)
        try require(formats.value as? String == "普通播放", "Expected ordinary projection")
        try checkPosition(elapsed, after: before)

        formats.tap()
        app.buttons["普通播放：切换到原生显示"].tap()
        try assertChangingEyes(in: app, surface: surface, mode: "native ordinary landscape")
        revealControls(surface)
        try checkPosition(elapsed, after: before)
        formats.tap()
        try require(app.buttons["普通播放：切换到兼容显示"].exists, app.debugDescription)
    }

    func testSystemPlayerShowsChanging4KHEVCSamplesBeyond4GiBInOrdinaryAndVR() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchMovie("moving4k-index", fileExtension: "bin", samples: "moving4k-samples")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }

        let surface = app.descendants(matching: .any)["playbackSurfaceToggle"]
        try require(surface.waitForExistence(timeout: 15), app.debugDescription)
        let format = app.buttons["videoFormatButton"]
        let systemRoute = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前解码：系统播放器")).firstMatch
        try assertChangingEyes(in: app, surface: surface, mode: "4K HEVC ordinary")
        revealControls(surface)
        format.tap()
        try require(systemRoute.exists, app.debugDescription)
        app.buttons["全宽 SBS（Full SBS）"].tap()

        try assertChangingEyes(in: app, surface: surface, mode: "4K HEVC full SBS")
        revealControls(surface)
        format.tap()
        try require(systemRoute.exists, app.debugDescription)
        app.buttons["退出 VR，普通播放"].tap()
        try assertChangingEyes(in: app, surface: surface, mode: "4K HEVC after leaving VR")
    }

    private func launchMovie(_ resource: String, fileExtension: String, samples: String? = nil) throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        func encoded(_ name: String) throws -> String {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: fileExtension))
            let data = try Data(contentsOf: url) as NSData
            // Simulator processes limit the total size of launch arguments and environment.
            return try data.compressed(using: .zlib).base64EncodedString()
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-moving-video"]
        app.launchEnvironment["NICE_UI_TEST_MOVIE"] = try encoded(resource)
        if let samples { app.launchEnvironment["NICE_UI_TEST_SAMPLES"] = try encoded(samples) }
        app.launch()
        return app
    }

    private struct MotionFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // A failed pixel check must unwind this test and terminate its app before
    // XCTest starts the next case. A detached async test could keep tapping it.
    private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw MotionFailure(message()) }
    }

    private func checkPosition(_ elapsed: XCUIElement, after previous: Int) throws {
        let shown = try seconds(elapsed)
        try require(shown >= previous - 1, "Playback position reset from \(previous) to \(shown) seconds")
    }

    private func seconds(_ label: XCUIElement) throws -> Int {
        let fields = label.label.split(separator: ":")
        guard fields.count >= 2 else { throw NSError(domain: "Missing elapsed time: " + label.label, code: 1) }
        return try fields.reduce(0) { $0 * 60 + (try XCTUnwrap(Int($1))) }
    }

    private func revealControls(_ surface: XCUIElement) {
        // Inside the control panel's padding when visible, inside the video tap
        // target otherwise. This point never toggles playing video controls off.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.95)).tap()
    }

    private func assertChangingEyes(in app: XCUIApplication, surface: XCUIElement, mode: String) throws {
        let viewport = surface.frame
        let window = app.frame
        guard !viewport.isEmpty, !window.isEmpty else {
            throw MotionFailure("Missing video bounds for \(mode): surface \(viewport), window \(window)")
        }
        var phases = Set<Int>()
        var last = ""
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let shot = XCUIScreen.main.screenshot()
            let colors = try sampleEyes(image: shot.image, viewport: viewport, window: window)
            let (left, right) = colors
            last = "\(left), \(right)"
            if left.r > left.g + 55 && left.r > left.b + 55
                && right.b > right.r + 55 && right.b > right.g + 55 { phases.insert(0) }
            if left.g > left.r + 55 && left.g > left.b + 55
                && right.r > right.b + 55 && right.g > right.b + 55 { phases.insert(1) }
            if phases.count == 2 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = mode
        attachment.lifetime = .keepAlways
        add(attachment)
        throw MotionFailure("\(mode): expected red/blue AND green/yellow on screen, got phases \(phases), last RGB pair \(last), surface \(viewport), window \(window)")
    }

    private typealias RGB = (r: Int, g: Int, b: Int)

    // Sample the system-composited screenshot. Time labels and transport
    // controls sit outside the centers of the two eye images.
    private func sampleEyes(image: UIImage, viewport: CGRect, window: CGRect) throws -> (RGB, RGB) {
        let w = 96, h = 54
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            UIGraphicsPopContext()
        }
        func pixel(at fraction: CGFloat) -> RGB {
            let relativeX = (viewport.minX + fraction * viewport.width - window.minX) / window.width
            let relativeY = (viewport.midY - window.minY) / window.height
            let x = min(w - 1, max(0, Int(relativeX * CGFloat(w))))
            let y = min(h - 1, max(0, Int(relativeY * CGFloat(h))))
            let i = 4 * (y * w + x)
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
        }
        return (pixel(at: 0.25), pixel(at: 0.75))
    }
}
