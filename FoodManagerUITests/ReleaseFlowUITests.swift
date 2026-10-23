import XCTest

/// Phase 5 release regression: refrigerator limit and switching, magnet decoration save/cancel, backup entry
/// points. Runs with `--uitesting` (isolated in-memory data, no iCloud, no ads).
final class ReleaseFlowUITests: XCTestCase {
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

    private func openFridgeManagement() {
        element("home.settings").tap()
        XCTAssertTrue(app.staticTexts["管理冰箱"].waitForExistence(timeout: 3))
        app.staticTexts["管理冰箱"].tap()
        XCTAssertTrue(element("fridgeManagement").waitForExistence(timeout: 3))
    }

    func testSecondFridgeIsAllowedThirdIsRejectedAndSwitchingWorks() throws {
        openFridgeManagement()
        element("fridgeManagement.add").tap()
        let name = app.textFields["fridge.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Pantry")
        app.buttons["使用預設隔層"].tap()
        // Creating switches to the new fridge.
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 4))

        openFridgeManagement()
        XCTAssertTrue(app.staticTexts["我的冰箱"].exists)
        element("fridgeManagement.add").tap()
        XCTAssertTrue(app.staticTexts["目前最多可建立 2 台冰箱。"].waitForExistence(timeout: 3), "third fridge rejected")
        app.buttons["好"].tap()

        app.staticTexts["我的冰箱"].tap()
        app.buttons["切換到這台冰箱"].tap()
        XCTAssertTrue(app.staticTexts["我的冰箱"].waitForExistence(timeout: 4))
        XCTAssertTrue(element("home.decorate").exists, "back on the closed fridge")
    }

    func testDecorationIsSavedAndCancelRestoresIt() throws {
        element("home.decorate").tap()
        XCTAssertTrue(element("magnets.editor").waitForExistence(timeout: 3))
        element("magnets.add").tap()
        app.buttons["內建磁鐵"].tap()
        let firstMagnet = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'magnets.catalog.'")).firstMatch
        XCTAssertTrue(firstMagnet.waitForExistence(timeout: 3))
        firstMagnet.tap()
        XCTAssertTrue(element("magnets.duplicate").waitForExistence(timeout: 3))
        element("magnets.duplicate").tap()
        element("magnets.save").tap()

        // Back on the closed fridge with two magnets on the door; tapping the door still opens it.
        XCTAssertTrue(element("home.decorate").waitForExistence(timeout: 3))
        XCTAssertEqual(app.otherElements.matching(identifier: "magnet.內建磁鐵").count, 2)

        // Cancel after deleting one: nothing changes.
        element("home.decorate").tap()
        XCTAssertTrue(element("magnets.editor").waitForExistence(timeout: 3))
        let board = element("magnets.board")
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        if element("magnets.delete").isEnabled { element("magnets.delete").tap() }
        element("magnets.cancel").tap()
        if app.buttons["放棄變更"].waitForExistence(timeout: 2) { app.buttons["放棄變更"].tap() }
        XCTAssertTrue(element("magnets.editor").waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.otherElements.matching(identifier: "magnet.內建磁鐵").count, 2, "cancel restored the arrangement")

        element("home.openFridge").tap()
        XCTAssertTrue(app.buttons["關上冰箱"].waitForExistence(timeout: 3), "magnets never block opening the door")
    }

    func testDataManagementEntriesAndNoPaidEntryPoints() throws {
        element("home.settings").tap()
        XCTAssertTrue(element("settings.cloudSync").waitForExistence(timeout: 3))
        XCTAssertTrue(element("settings.exportBackup").exists)
        XCTAssertTrue(element("settings.importBackup").exists)
        XCTAssertFalse(element("settings.upgrade").exists, "no purchase UI in 1.0")
        XCTAssertFalse(element("settings.restore").exists)
        element("settings.cloudSync").tap()
        XCTAssertTrue(element("cloudSync.toggle").waitForExistence(timeout: 3))
    }
}
