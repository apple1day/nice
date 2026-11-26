import UIKit
import XCTest

@MainActor
final class VRFolderLibraryUITests: XCTestCase {
    func testSelectFolderBrowseVideoDetailsPlayDirectlyAndRestoreAfterRelaunch() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "panorama-chart", withExtension: "mp4"))
        let fixture = try Data(contentsOf: fixtureURL)
        app.launchArguments = ["--ui-test-vr-folder", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NICE_VR_FOLDER_TEST_ID"] = UUID().uuidString

        func openVRTab() {
            let byID = app.tabBars.buttons["vrFolderTab"]
            let button = byID.exists ? byID : app.tabBars.buttons["VR"]
            XCTAssertTrue(button.waitForExistence(timeout: 12), app.debugDescription)
            button.tap()
        }
        func control(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func cancelFilesPicker() {
            let cancel = app.buttons.matching(NSPredicate(
                format: "label IN %@", ["Cancel", "Close", "取消", "关闭"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
            cancel.tap()
        }

        // Exercise the real Files picker without assuming a particular account
        // or an installed File Provider. A newly cancelled grant adds no root.
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        openVRTab()
        let choose = control("vrChooseFolderButton")
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        attachVRScreen("VR-library-home")
        choose.tap()
        cancelFilesPicker()
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        XCTAssertFalse(control("vrRoot-VR 示例").exists)

        // Accept a deterministic directory at the picker callback boundary.
        // All subsequent storage, thumbnails, player entry and restoration use
        // the same code as a directory returned by a real external provider.
        app.terminate()
        app.launchEnvironment["NICE_VR_FOLDER_MOVIE"] = try (fixture as NSData).compressed(using: .zlib).base64EncodedString()
        app.launch()
        openVRTab()
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.tap()
        let rootMovie = control("vrEntry-Panorama Demo.mp4")
        XCTAssertTrue(rootMovie.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(rootMovie.label.contains("Panorama Demo.mp4"), rootMovie.label)
        XCTAssertTrue(rootMovie.label.contains("MP4"), rootMovie.label)
        let size = ByteCountFormatter.string(fromByteCount: Int64(fixture.count), countStyle: .file)
        let numberText = size.components(separatedBy: .whitespacesAndNewlines).first ?? size
        XCTAssertTrue(rootMovie.label.contains(numberText), "Expected file size \(size) in \(rootMovie.label)")
        XCTAssertFalse(control("vrEntry-notes.txt").exists)
        XCTAssertTrue(try hasChartThumbnail(rootMovie), "Expected the film's colored preview inside its list row")

        XCTAssertTrue(rootMovie.label.contains("384 × 192"), rootMovie.label)
        XCTAssertTrue(rootMovie.label.contains("01:00"), rootMovie.label)
        attachVRScreen("VR-library-folder")
        let subfolder = control("vrEntry-旅行")
        XCTAssertTrue(subfolder.exists)
        subfolder.tap()
        let child = control("vrEntry-Trip.mov")
        XCTAssertTrue(child.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(rootMovie.exists)
        child.tap()
        let surface = control("playbackSurfaceToggle")
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        // The controls auto-hide after four seconds of playing. Renew their
        // deadline using the transport's empty margin, then pause the real
        // player before inspecting the HUD. Pausing keeps controls visible.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.95)).tap()
        let toggle = app.buttons["togglePlaybackButton"]
        func waitFor(_ message: String, timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) {
            if condition() { return }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, message)
        }
        waitFor("Player did not expose an enabled pause control") {
            toggle.exists && toggle.label == "暂停" && toggle.isEnabled && toggle.isHittable
        }
        toggle.tap()
        waitFor("The real movie did not pause") { toggle.exists && toggle.label == "播放" && toggle.isHittable }
        // No mode menu was opened: the folder row directly entered immersive viewing.
        XCTAssertTrue(app.buttons["vrHeadsetButton"].isHittable)
        XCTAssertEqual(app.buttons["videoFormatButton"].value as? String, "180° 全景")
        let close = app.buttons["closeFullscreenPlayer"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        let back = control("vrFolderBackButton")
        waitFor("Player cover was not dismissed over the child's folder", timeout: 12) {
            !surface.exists && back.exists && back.isHittable && child.exists && child.isHittable
        }
        back.tap()
        XCTAssertTrue(rootMovie.waitForExistence(timeout: 8))

        // Launch without a test URL: a previously stored bookmark is now the
        // only route to this directory. Cancellation must preserve it.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NICE_VR_FOLDER_MOVIE")
        app.launch()
        openVRTab()
        XCTAssertTrue(rootMovie.waitForExistence(timeout: 12), app.debugDescription)
        control("vrFolderActions").tap()
        let replace = control("vrReplaceFolder")
        (replace.exists ? replace : app.buttons["更换文件夹"]).tap()
        cancelFilesPicker()
        XCTAssertTrue(rootMovie.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(subfolder.exists)
    }

    func testCompatibleCopyFormOpensBeforePlaybackAndRequiresBothLocations() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-vr-folder"]
        app.launchEnvironment["NICE_VR_FOLDER_TEST_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let tab = app.tabBars.buttons["vrFolderTab"]
        (tab.exists ? tab : app.tabBars.buttons["VR"]).tap()
        let entry = app.buttons["makeCompatibleCopy"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.buttons["compatibleCopySource"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["compatibleCopyDestination"].isHittable)
        XCTAssertFalse(app.buttons["startCompatibleCopy"].isEnabled)
        XCTAssertFalse(app.buttons["playGeneratedCopy"].exists)
        attachVRScreen("Compatible copy source and destination")
        app.buttons["closeCompatibleCopy"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
    }

    func testAfterglowPresetAppliesBeforeFolderMovieAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "panorama-chart", withExtension: "mp4"))
        app.launchArguments = ["--ui-test-vr-folder"]
        app.launchEnvironment["NICE_VR_FOLDER_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["NICE_VR_FOLDER_MOVIE"] = try (Data(contentsOf: url) as NSData)
            .compressed(using: .zlib).base64EncodedString()
        func control(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func openTab() {
            app.launch()
            let byID = app.tabBars.buttons["vrFolderTab"]
            let tab = byID.exists ? byID : app.tabBars.buttons["VR"]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.tap()
        }
        openTab()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(control("afterglowOpenVideo").exists)
        attachVRScreen("Afterglow XR entry")
        control("afterglowOpenSettings").tap()
        let headset = app.switches.matching(identifier: "vrHeadsetToggle").firstMatch
        XCTAssertTrue(headset.waitForExistence(timeout: 6), app.debugDescription)
        attachVRScreen("Afterglow XR playback presets")
        if headset.value as? String == "1" {
            headset.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        }
        let singleScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: headset)
        XCTAssertEqual(XCTWaiter.wait(for: [singleScreen], timeout: 5), .completed)
        XCTAssertTrue(control("afterglowFrameRate").exists)
        control("afterglowSettingsDone").tap()
        app.terminate()
        openTab()
        control("vrChooseFolderButton").tap()
        let play = control("afterglowEntry-Panorama Demo.mp4")
        XCTAssertTrue(play.waitForExistence(timeout: 12))
        play.tap()
        let surface = control("playbackSurfaceToggle")
        XCTAssertTrue(surface.waitForExistence(timeout: 12), app.debugDescription)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.95)).tap()
        let toggle = app.buttons["togglePlaybackButton"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true AND label == %@", "暂停"),
            object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed, app.debugDescription)
        toggle.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "播放"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 6), .completed, app.debugDescription)
        let format = control("videoFormatButton")
        XCTAssertEqual(format.value as? String, "360° 全景")
        XCTAssertEqual(control("vrHeadsetButton").label, "切换双眼眼镜")
        format.tap()
        XCTAssertTrue(control("copyPlaybackDiagnostics").waitForExistence(timeout: 6))
        let decoder = control("vrCurrentDecoder")
        for _ in 0..<4 {
            if decoder.exists && decoder.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(decoder.exists && decoder.isHittable, app.debugDescription)
        XCTAssertEqual(decoder.value as? String, "Afterglow XR", app.debugDescription)
    }

    private func attachVRScreen(_ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // UIKit accessibility intentionally describes the row, not its decorative
    // thumbnail. Validate pixels of the real composited row: this chart has a
    // yellow-green region; a gray/blue placeholder, text, or spinner does not.
    private func hasChartThumbnail(_ row: XCUIElement) throws -> Bool {
        let deadline = Date().addingTimeInterval(12)
        repeat {
            let image = row.screenshot().image
            let width = 128, height = 32
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let coloredPixels = try bytes.withUnsafeMutableBytes { data -> Int in
                let ctx = try XCTUnwrap(CGContext(data: data.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                UIGraphicsPushContext(ctx)
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                UIGraphicsPopContext()
                let rgb = data.bindMemory(to: UInt8.self)
                var count = 0
                for y in 0..<height {
                    for x in 0..<(width / 2) {
                        let offset = (y * width + x) * 4
                        let r = Int(rgb[offset]), g = Int(rgb[offset + 1]), b = Int(rgb[offset + 2])
                        if r > 100 && g > 105 && min(r, g) - b > 35 { count += 1 }
                    }
                }
                return count
            }
            if coloredPixels > 8 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.20))
        } while Date() < deadline
        let attachment = XCTAttachment(screenshot: row.screenshot())
        attachment.name = "VR folder video preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        return false
    }
}
