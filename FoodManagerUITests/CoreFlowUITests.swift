import XCTest

/// Representative end-to-end flows. The app is launched with `--uitesting`, which explicitly uses an
/// isolated in-memory store (never the user's data) and starts from an empty, closed fridge.
final class CoreFlowUITests: XCTestCase {
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

    private func dismissPermissionPromptIfShown() {
        let notNow = app.alerts.buttons["暫時不要"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    func testAddFoodUpdatesDashboardAndOpensReminderCenterWithFilter() throws {
        element("home.addFood").tap()
        let name = app.textFields["food.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Milk")

        app.buttons["food.location"].tap()
        app.buttons["櫃內 · 上層（冷藏）"].firstMatch.tap()
        app.switches["food.expirySwitch"].tap() // expiry defaults to today → "expiring soon"
        app.buttons["food.save"].tap()
        dismissPermissionPromptIfShown()

        let expiring = element("dashboard.expiringSoon")
        XCTAssertTrue(expiring.waitForExistence(timeout: 3))
        XCTAssertTrue(expiring.label.contains("1 項"), expiring.label)
        expiring.tap()

        XCTAssertTrue(app.navigationBars["食材提醒"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: 2))
        XCTAssertTrue(element("reminder.tile.expiringSoon").isSelected, "opened pre-filtered to 即將到期")

        app.navigationBars["食材提醒"].buttons.firstMatch.tap()
        XCTAssertTrue(element("home.openFridge").waitForExistence(timeout: 3), "back on the closed fridge")
    }

    func testReminderCenterAndSettingsKeepDoorState() throws {
        element("home.openFridge").tap()
        let closeDoor = app.buttons["關上冰箱"]
        XCTAssertTrue(closeDoor.waitForExistence(timeout: 3))

        element("home.reminders").tap()
        XCTAssertTrue(app.navigationBars["食材提醒"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["目前沒有需要注意的食材"].exists, "empty only after a successful read")

        app.navigationBars["食材提醒"].buttons["通知設定"].tap()
        XCTAssertTrue(app.navigationBars["通知設定"].waitForExistence(timeout: 3))
        app.navigationBars["通知設定"].buttons.firstMatch.tap()
        app.navigationBars["食材提醒"].buttons.firstMatch.tap()

        XCTAssertTrue(closeDoor.waitForExistence(timeout: 3), "door is still open after returning")
    }
}
