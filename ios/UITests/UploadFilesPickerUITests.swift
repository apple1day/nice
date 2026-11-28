import XCTest

@MainActor
final class UploadFilesPickerUITests: XCTestCase {
    func testOpenAndCancelFilesWithoutEnqueuingAndKeepDownloadedPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-file-picker", "-server", "http://127.0.0.1:9",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 12))
        let uploadTab = app.tabBars.buttons["上传"]
        if uploadTab.exists {
            uploadTab.tap()
        } else {
            // A compact iPhone puts the fifth and sixth tabs in More.
            let more = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
            XCTAssertTrue(more.exists, app.debugDescription)
            more.tap()
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "上传")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
        }
        let files = app.buttons["chooseFilesToUploadButton"]
        let downloads = app.buttons["chooseVideosToUploadButton"]
        XCTAssertTrue(files.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(downloads.exists)
        let jobRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'uploadJob.'"))
        let initialCount = jobRows.count
        files.tap()

        // Drive the actual Files picker without depending on any installed providers.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close", "取消", "关闭"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
        cancel.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !cancel.exists && downloads.exists && downloads.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["confirmFilesUploadButton"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(jobRows.count, initialCount)

        downloads.tap()
        XCTAssertTrue(app.navigationBars["选择上传视频"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["confirmSelectedUploadsButton"].isEnabled)
    }
}
