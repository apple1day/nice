import XCTest

// Use real screen coordinates, not accessibility adjustment or calls into the
// scrub controller. This exercises UIKit hit testing and the production layers.
@MainActor final class PlaybackScrubbingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-playback"]
        app.launch()
        XCTAssertTrue(element("uiTestPlaybackPhase").waitForExistence(timeout: 10),
                      "Player fixture failed to launch: \(app.debugDescription)")
        waitUntil("The fake decoder should be playing") {
            self.element("uiTestPlaybackPhase").label == "playing"
        }
        XCTAssertEqual(element("uiTestCurrentItem").label, "uitest-1.mp4")
        XCTAssertEqual(try integer("uiTestSeekCount"), 0)
    }

    override func tearDown() async throws {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testTrackDragsSeekForwardAndBackwardWithoutBouncing() throws {
        // Playback starts near 10%; both gestures deliberately start on the
        // track away from the thumb, which was difficult to acquire previously.
        let forward = try dragProgress(from: 0.35, to: 0.78, phase: "playing")
        let backward = try dragProgress(from: 0.62, to: 0.23, phase: "playing")
        XCTAssertGreaterThan(forward - backward, 45)
    }

    func testPausedPlaybackRemainsPausedAfterDragging() throws {
        try ensureControlsVisible()
        element("togglePlaybackButton").tap()
        waitUntil("Pause should reach the playback model") {
            self.element("uiTestPlaybackPhase").label == "paused"
        }
        let target = try dragProgress(from: 0.30, to: 0.62, phase: "paused")
        XCTAssertEqual(try number("uiTestPlaybackSeconds"), target, accuracy: 0.01)
        XCTAssertEqual(element("uiTestPlaybackPhase").label, "paused")
    }

    func testFullscreenLandscapeAndNextVideoKeepDraggingAvailable() throws {
        try ensureControlsVisible()
        element("toggleFullscreenButton").tap()
        waitUntil("The production player should enter fullscreen") {
            self.element("toggleFullscreenButton").value as? String == "全屏"
        }
        _ = try dragProgress(from: 0.32, to: 0.68, phase: "playing")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil("The player should finish rotating to landscape") {
            self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height
        }
        _ = try dragProgress(from: 0.60, to: 0.24, phase: "playing")

        try ensureControlsVisible()
        XCTAssertTrue(element("nextVideoButton").isEnabled)
        element("nextVideoButton").tap()
        waitUntil("Next should attach a new player to the production hierarchy") {
            self.element("uiTestCurrentItem").label == "uitest-2.mp4"
                && self.element("uiTestPlaybackPhase").label == "playing"
        }
        _ = try dragProgress(from: 0.30, to: 0.73, phase: "playing")
    }

    @discardableResult
    private func dragProgress(from startFraction: CGFloat, to endFraction: CGFloat,
                              phase: String, file: StaticString = #filePath,
                              line: UInt = #line) throws -> Double {
        // Read probes before revealing the controls. Each AX lookup is a round
        // trip, and the production player correctly auto-hides after four seconds.
        let seeksBefore = try integer("uiTestSeekCount")
        let frame = try ensureControlsVisible(file: file, line: line)
        XCTAssertGreaterThan(frame.width, 120, "Progress must fill the controls", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44, "Touch height must stay usable", file: file, line: line)
        // Reuse the frame just observed, without resolving the slider again
        // between showing the controls and putting the finger down.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * startFraction, dy: frame.midY))
        let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * endFraction, dy: frame.midY))
        start.press(forDuration: 0.35, thenDragTo: end)

        waitUntil("Releasing a drag must perform exactly one engine seek", file: file, line: line) {
            Int(self.element("uiTestSeekCount").label) == seeksBefore + 1
        }
        let target = try number("uiTestLastSeek")
        // Allow the visual track's thumb inset without copying its geometry.
        XCTAssertEqual(target, Double(endFraction) * 120, accuracy: 8, file: file, line: line)
        XCTAssertEqual(element("uiTestPlaybackPhase").label, phase, file: file, line: line)

        let tickAtRelease = try integer("uiTestTickCount")
        waitUntil("Several decoder updates must arrive after release", file: file, line: line) {
            (Int(self.element("uiTestTickCount").label) ?? -1) >= tickAtRelease + 3
        }
        XCTAssertEqual(try integer("uiTestSeekCount"), seeksBefore + 1,
                       "A single gesture must not commit more than once", file: file, line: line)
        let seconds = try number("uiTestPlaybackSeconds")
        XCTAssertGreaterThanOrEqual(seconds, target - 0.1, "Playback must not snap back", file: file, line: line)
        XCTAssertLessThan(seconds, target + 6, "Playback should continue near the selected time", file: file, line: line)

        // Check the user's actual elapsed-time label as well as the engine probe.
        try ensureControlsVisible(file: file, line: line)
        let displayed = try displayedSeconds(element("playbackElapsedTime").label)
        XCTAssertEqual(displayed, try number("uiTestPlaybackSeconds"), accuracy: 2, file: file, line: line)
        return target
    }

    @discardableResult
    private func ensureControlsVisible(file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let progress = element("playbackProgressSlider")
        // Only tap when hidden. Blindly tapping the surface can hide controls
        // which are already visible and turn a gesture test into a timing race.
        if !progress.isHittable {
            let surface = element("playbackSurfaceToggle")
            XCTAssertTrue(surface.exists, file: file, line: line)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        waitUntil("Progress must be visible and ready to receive real touches", file: file, line: line) {
            progress.isHittable
        }
        // One snapshot supplies both properties. Do not perform three separate
        // AX lookups on every visibility poll or conflate layout/enable failures.
        let snapshot = try progress.snapshot()
        XCTAssertTrue(snapshot.isEnabled, "Visible progress is disabled: \(snapshot.dictionaryRepresentation)",
                      file: file, line: line)
        return snapshot.frame
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func integer(_ identifier: String) throws -> Int {
        try XCTUnwrap(Int(element(identifier).label), "Missing numeric probe: \(identifier)")
    }

    private func number(_ identifier: String) throws -> Double {
        try XCTUnwrap(Double(element(identifier).label), "Missing numeric probe: \(identifier)")
    }

    private func displayedSeconds(_ label: String) throws -> Double {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        XCTAssertTrue(parts.count == 2 || parts.count == 3, "Unexpected elapsed time: \(label)")
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 6,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result != .completed else { return }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Playback UI wait failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let details = playbackFailureDiagnostics()
        let hierarchy = app.debugDescription
        let attachment = XCTAttachment(string: details + "\n\n" + hierarchy)
        attachment.name = "Playback accessibility state"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(message + "\n" + details + "\n\n" + hierarchy, file: file, line: line)
    }

    private func playbackFailureDiagnostics() -> String {
        func describe(_ candidate: XCUIElement) -> String {
            guard candidate.exists else { return "exists=false" }
            guard let snapshot = try? candidate.snapshot() else { return "exists=true, snapshot unavailable" }
            return "exists=true, hittable=\(candidate.isHittable), enabled=\(snapshot.isEnabled), "
                + "frame=\(snapshot.frame), width>120=\(snapshot.frame.width > 120), "
                + "height>=44=\(snapshot.frame.height >= 44), "
                + "identifier=\(snapshot.identifier), label=\(snapshot.label)"
        }
        // A label candidate is diagnostic only; gestures must still find the
        // actual identifier so an inherited parent ID cannot silently pass.
        let byLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        return "Progress by identifier: \(describe(element("playbackProgressSlider")))\n"
            + "Progress by label: \(describe(byLabel))"
    }
}
