import XCTest

@MainActor
final class LocalFilePickerUITests: XCTestCase {
    func testOpenAndCancelSystemFilesFromEmptyLocalLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-file-picker", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }

        let open = app.buttons["openVideoFileButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["selectLocalVideosButton"].isEnabled)
        open.tap()

        // Files provides its own cancel/close item; keep the test independent
        // of configured iCloud accounts, Recent documents and installed providers.
        let cancel = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Close", "取消", "关闭"]
        )).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12))
        cancel.tap()

        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !cancel.exists && open.exists && open.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["videoFormatButton"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
