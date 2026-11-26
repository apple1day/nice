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

    func testPickedPanoramaCanLookAroundRecenterAndPlayInBothEyes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchMovie("panorama-chart", fileExtension: "mp4")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let surface = app.descendants(matching: .any)["playbackSurfaceToggle"]
        try require(surface.waitForExistence(timeout: 15), app.debugDescription)
        revealControls(surface)
        let formats = app.buttons["videoFormatButton"]
        formats.tap()
        let enter = app.buttons["进入全景 VR"]
        try require(enter.waitForExistence(timeout: 5), app.debugDescription)
        enter.tap()

        func checkChart(_ description: String, stereo: Bool = false,
                        moving: Bool = false, panned: Bool = false) throws {
            var phases = Set<Int>()
            var last = ""
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let pair = try sampleEyes(image: XCUIScreen.main.screenshot().image,
                                          viewport: surface.frame, window: app.frame,
                                          fractions: stereo ? (0.25, 0.75) : (0.5, 0.5))
                last = "\(pair)"
                let eye = pair.0
                let longitudeMatches = panned ? eye.r > 148 : abs(eye.r - 128) < 16
                if longitudeMatches && abs(eye.g - 128) < 16 && (20...96).contains(eye.b) {
                    let phase = eye.b < 58 ? 0 : 1
                    if !stereo || (abs(pair.1.r - 128) < 16 && abs(pair.1.g - 128) < 16
                        && abs((pair.1.b - eye.b) - 128) < 12) {
                        phases.insert(phase)
                        if !moving || phases.count == 2 { return }
                    }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = description
            attachment.lifetime = .keepAlways
            add(attachment)
            throw MotionFailure("\(description): phases=\(phases), RGB=\(last)")
        }

        let transport = app.buttons.matching(identifier: "togglePlaybackButton")
        let pause = transport.matching(NSPredicate(format: "label == %@", "暂停")).firstMatch
        let play = transport.matching(NSPredicate(format: "label == %@", "播放")).firstMatch
        func pauseForControls() throws {
            // Paused playback keeps the toolbar visible. A tap during its fade
            // can reveal the toolbar instead, so confirm the actual transport state.
            for _ in 0..<2 {
                if play.exists && play.isHittable { return }
                if !pause.exists || !pause.isHittable { revealControls(surface) }
                if pause.waitForExistence(timeout: 2) && pause.isHittable { pause.tap() }
                if play.waitForExistence(timeout: 2) && play.isHittable { return }
            }
            throw MotionFailure("Could not pause panorama with its transport button: " + app.debugDescription)
        }

        try checkChart("single-eye panorama updates", moving: true)
        let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.5))
        from.press(forDuration: 0.15, thenDragTo: to)
        try checkChart("leftward drag turns right", panned: true)
        try pauseForControls()
        app.buttons["vrRecenterButton"].tap()
        try checkChart("recenter shows forward ray")
        app.buttons["vrHeadsetButton"].tap()
        play.tap()
        try checkChart("both eyes move in sync", stereo: true, moving: true)
        try pauseForControls()
        formats.tap()
        try require(app.navigationBars["VR 设置"].waitForExistence(timeout: 5), app.debugDescription)
        let copy = app.buttons["copyPlaybackDiagnostics"]
        try require(copy.waitForExistence(timeout: 5) && copy.isHittable, "Missing diagnostics action")
        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已复制"), object: copy)
        try require(XCTWaiter.wait(for: [copied], timeout: 4) == .completed, "Diagnostics did not copy")
        let exitVR = app.buttons["exitPanoramaVR"]
        // A landscape Form only materializes its visible rows. Scroll inside
        // the sheet until its exit action is on screen, as a viewer would.
        for _ in 0..<8 {
            if exitVR.exists && exitVR.isHittable { break }
            app.swipeUp()
        }
        try require(exitVR.exists && exitVR.isHittable, "VR exit action unavailable: " + app.debugDescription)
        exitVR.tap()
        let normal = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in formats.exists && formats.value as? String == "普通播放" },
            object: nil)
        try require(XCTWaiter.wait(for: [normal], timeout: 6) == .completed,
                    "Leaving the VR settings did not restore ordinary playback")
    }

    func testResumed360HeadsetMovieContinuesChangingBothEyes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchMovie("moving4k-index", fileExtension: "bin", samples: "moving4k-samples", resume360: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let surface = app.descendants(matching: .any)["playbackSurfaceToggle"]
        try require(surface.waitForExistence(timeout: 20), app.debugDescription)

        try assertChangingEyes(in: app, surface: surface, mode: "resumed 4K 360-degree headset")
        revealControls(surface)
        let elapsed = try seconds(app.staticTexts["playbackElapsedTime"])
        try require(elapsed >= 142, "Expected a saved playback position near 02:23, got \(elapsed)")
        let format = app.buttons["videoFormatButton"]
        try require(format.value as? String == "360° 全景", app.debugDescription)
        try assertChangingEyes(in: app, surface: surface, mode: "both projected eyes after resume")

    }

    private func launchMovie(_ resource: String, fileExtension: String, samples: String? = nil,
                             resume360: Bool = false) throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        func encoded(_ name: String) throws -> String {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: fileExtension))
            let data = try Data(contentsOf: url) as NSData
            // Simulator processes limit the total size of launch arguments and environment.
            return try data.compressed(using: .zlib).base64EncodedString()
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-moving-video"]
        if resume360 { app.launchEnvironment["NICE_UI_TEST_RESUME_360"] = "1" }
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
    private func sampleEyes(image: UIImage, viewport: CGRect, window: CGRect,
                            fractions: (CGFloat, CGFloat) = (0.25, 0.75)) throws -> (RGB, RGB) {
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
        return (pixel(at: fractions.0), pixel(at: fractions.1))
    }
}
