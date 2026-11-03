import XCTest

// Exercise the actual SwiftUI player and native surface lifecycle. The Debug
// decoder reports EOF from its running clock; the test never calls move/next.
@MainActor final class PlaybackAutoplayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-playback", "--ui-test-autoplay"]
        app.launch()
        XCTAssertTrue(element("uiTestPlaybackPhase").waitForExistence(timeout: 10),
                      "Player fixture failed to launch: \(app.debugDescription)")
        waitUntil("The first native surface should mount and start playback") {
            self.element("uiTestCurrentItem").label == "uitest-1.mp4"
                && self.element("uiTestPlaybackPhase").label == "playing"
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testNaturalEndMountsAndPlaysNextSurfaceThenStopsAtPlaylistEnd() throws {
        XCTAssertEqual(element("uiTestAttachCount").label, "1")
        XCTAssertEqual(element("uiTestLoadCount").label, "1")
        try seekNearEnd()

        waitUntil("EOF should attach and play the next video without a Next tap") {
            self.element("uiTestCurrentItem").label == "uitest-2.mp4"
                && self.element("uiTestPlaybackPhase").label == "playing"
        }
        XCTAssertTrue(app.navigationBars["uitest-2.mp4"].exists,
                      "The visible production navigation title must follow the new video")
        XCTAssertEqual(element("uiTestAttachCount").label, "2")
        XCTAssertEqual(element("uiTestLoadCount").label, "2")
        XCTAssertEqual(element("uiTestStopCount").label, "1",
                       "The previous decoder must be stopped before the new surface plays")

        try seekNearEnd()
        waitUntil("The last item should end without wrapping to the first") {
            self.element("uiTestCurrentItem").label == "uitest-2.mp4"
                && self.element("uiTestPlaybackPhase").label == "ended"
        }
        // The fixture deliberately keeps reporting terminal snapshots. Observe
        // several more ticks to catch duplicate completion or unintended loops.
        let ticksAtEnd = try XCTUnwrap(Int(element("uiTestTickCount").label))
        waitUntil("Terminal decoder updates should remain on the last item") {
            (Int(self.element("uiTestTickCount").label) ?? 0) >= ticksAtEnd + 5
        }
        XCTAssertEqual(element("uiTestCurrentItem").label, "uitest-2.mp4")
        XCTAssertEqual(element("uiTestPlaybackPhase").label, "ended")
        XCTAssertEqual(element("uiTestAttachCount").label, "2")
        XCTAssertEqual(element("uiTestLoadCount").label, "2")
        XCTAssertEqual(element("uiTestStopCount").label, "1")
    }

    func testDragHeldAcrossEOFCommitsOnSameVideoBeforeAutoplayCanContinue() throws {
        let frame = try visibleProgressFrame()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.45, dy: frame.midY))
        let nearEnd = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.70, dy: frame.midY))
        let earlier = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.25, dy: frame.midY))

        // Commit near 21/30 seconds, then put the finger down again immediately.
        // Reuse the observed frame: AX lookups between the gestures could let
        // the first video finish before the second drag even starts.
        start.press(forDuration: 0.25, thenDragTo: nearEnd)
        nearEnd.press(forDuration: 0.25, thenDragTo: earlier,
                      withVelocity: .slow, thenHoldForDuration: 12)

        waitUntil("Releasing the held drag should seek and resume the same video") {
            self.element("uiTestCurrentItem").label == "uitest-1.mp4"
                && self.element("uiTestPlaybackPhase").label == "playing"
                && self.element("uiTestSeekCount").label == "2"
        }
        XCTAssertEqual(element("uiTestEndCount").label, "1",
                       "The decoder must actually report EOF while the finger is held down")
        let target = try XCTUnwrap(Double(element("uiTestLastSeek").label))
        XCTAssertEqual(target, 7.5, accuracy: 1.5,
                       "The touch-up must apply its earlier target to the original video")
        let seconds = try XCTUnwrap(Double(element("uiTestPlaybackSeconds").label))
        XCTAssertGreaterThanOrEqual(seconds, target - 0.1)
        XCTAssertLessThan(seconds, target + 8,
                          "Playback should continue near the committed target")
        XCTAssertEqual(element("uiTestAttachCount").label, "1")
        // Only EOF recovery reloads the current media descriptor. It keeps the
        // same native surface and engine, without a teardown or another attach.
        XCTAssertEqual(element("uiTestLoadCount").label, "2")
        XCTAssertEqual(element("uiTestStopCount").label, "0")

        try seekNearEnd()
        waitUntil("After the drag has finished, a later natural EOF should advance normally") {
            self.element("uiTestCurrentItem").label == "uitest-2.mp4"
                && self.element("uiTestPlaybackPhase").label == "playing"
        }
        XCTAssertEqual(element("uiTestEndCount").label, "2")
        XCTAssertEqual(element("uiTestAttachCount").label, "2")
        XCTAssertEqual(element("uiTestLoadCount").label, "3")
        XCTAssertEqual(element("uiTestStopCount").label, "1")
    }

    private func visibleProgressFrame() throws -> CGRect {
        let surface = element("playbackSurfaceToggle")
        XCTAssertTrue(surface.exists)
        // The same safe transport-padding point used by the scrubbing tests
        // reveals/renews controls without toggling playback or hiding controls.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.95)).tap()
        let progress = element("playbackProgressSlider")
        waitUntil("The real progress slider should be ready") { progress.isHittable }
        let snapshot = try progress.snapshot()
        XCTAssertTrue(snapshot.isEnabled)
        return snapshot.frame
    }

    private func seekNearEnd() throws {
        let frame = try visibleProgressFrame()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.65, dy: frame.midY))
        let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.92, dy: frame.midY))
        start.press(forDuration: 0.25, thenDragTo: end)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) != .completed else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Autoplay UI failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = app.debugDescription
        let attachment = XCTAttachment(string: hierarchy)
        attachment.name = "Autoplay accessibility state"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(message + "\n" + hierarchy, file: file, line: line)
    }
}
