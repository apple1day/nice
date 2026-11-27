import XCTest

@MainActor
final class MissingLocalRecordUITests: XCTestCase {
    func testCancelThenRemoveMissingRecordKeepsOtherMovie() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-deleted-records"]
        app.launch()
        defer { app.terminate() }

        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeMissingRecord.")).firstMatch
        let kept = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                    "localVideoRow.", "Retained movie.mp4")).firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<3 {
                if element.exists && element.isHittable { return }
                app.swipeUp()
            }
        }
        XCTAssertTrue(remove.waitForExistence(timeout: 12), app.debugDescription)
        reveal(remove)
        XCTAssertTrue(remove.label.contains("Removed movie.mp4"))
        remove.tap()
        let confirm = app.buttons["确认移除记录"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch.tap()
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
        XCTAssertTrue(remove.exists)
        reveal(remove)
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 8), .completed)
        let result = app.staticTexts["batchDeletionSummary"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(result.label.contains("已移除 1 条记录"))
        reveal(kept)
        XCTAssertTrue(kept.exists, app.debugDescription)
    }
}
