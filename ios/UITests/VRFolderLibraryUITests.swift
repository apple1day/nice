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
        // The caller never opened a VR menu. These controls exist only after
        // the player has already entered immersive viewing.
        let headset = app.buttons["vrHeadsetButton"]
        func revealIfNeeded(_ target: XCUIElement) {
            if !target.isHittable {
                surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)).tap()
            }
        }
        revealIfNeeded(headset)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in headset.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(app.buttons["videoFormatButton"].value as? String, "180° 全景")
        let close = app.buttons["closeFullscreenPlayer"]
        revealIfNeeded(close)
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 8))
        control("vrFolderBackButton").tap()
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

    private func attachVRScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
