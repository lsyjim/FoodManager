import XCTest

/// Widget deep links opened into the running app (isolated in-memory store via `--uitesting`).
final class WidgetLinkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testQuickAddLinkOpensTheRegularAddForm() throws {
        app.open(URL(string: "foodmanager://add")!)
        XCTAssertTrue(app.textFields["food.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["新增食材"].exists)
        XCTAssertTrue(element("food.saveAndContinue").exists, "same editor with continuous entry")

        // Opening the link again keeps the one form.
        app.open(URL(string: "foodmanager://add")!)
        XCTAssertTrue(app.navigationBars["新增食材"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.navigationBars.matching(identifier: "新增食材").count, 1)
    }

    func testReminderLinkOpensFilteredReminderCenterAndBackReturnsHome() throws {
        app.open(URL(string: "foodmanager://reminders?storage=frozen&kind=expired")!)
        XCTAssertTrue(app.navigationBars["食材提醒"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["冷凍"].isSelected)
        XCTAssertTrue(element("reminder.tile.expired").isSelected)
        app.navigationBars["食材提醒"].buttons.firstMatch.tap()
        XCTAssertTrue(element("home.openFridge").waitForExistence(timeout: 3))
    }

    func testInvalidLinkStaysOnHome() throws {
        app.open(URL(string: "foodmanager://food?id=not-a-uuid")!)
        XCTAssertTrue(element("home.openFridge").waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["新增食材"].exists)
        XCTAssertFalse(app.navigationBars["食材提醒"].exists)
        // The transient message itself is asserted in HomeRoutingTests (XCUITest waits out its animation).
    }
}
