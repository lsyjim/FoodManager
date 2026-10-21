import XCTest

/// Phase 3.1 flows on an isolated in-memory store (`--uitesting`).
final class HistoryFlowUITests: XCTestCase {
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

    private func typeName(_ text: String) {
        let name = app.textFields["food.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(text)
    }

    private func chooseUpperShelf() {
        app.buttons["food.location"].tap()
        app.buttons["櫃內 · 上層（冷藏）"].firstMatch.tap()
    }

    func testContinuousEntryKeepsCompartmentAndOffersRecentFood() throws {
        element("home.addFood").tap()
        typeName("Tofu")
        chooseUpperShelf()
        element("food.saveAndContinue").tap()

        let name = app.textFields["food.name"]
        XCTAssertEqual(name.value as? String ?? "", "例如：牛奶", "name cleared (placeholder shown)")
        XCTAssertTrue(app.buttons["櫃內 · 上層（冷藏）"].exists || element("food.location").label.contains("上層"),
                      "compartment kept for the next entry")
        XCTAssertTrue(element("food.recent.Tofu").waitForExistence(timeout: 2), "just-added food is suggested")

        typeName("Egg")
        app.buttons["food.save"].tap()

        element("home.search").tap()
        XCTAssertTrue(app.staticTexts["Tofu"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Egg"].exists)
    }

    func testConsumeThenRestoreFromHistory() throws {
        element("home.addFood").tap()
        typeName("Milk")
        chooseUpperShelf()
        app.buttons["food.save"].tap()

        // Mark consumed from search → editor.
        element("home.search").tap()
        app.staticTexts["Milk"].firstMatch.tap()
        app.buttons["標記為已食用"].tap()
        XCTAssertTrue(app.staticTexts["冰箱裡還沒有食材"].waitForExistence(timeout: 3))

        // History shows it; restore puts it back.
        element("search.history").tap()
        XCTAssertTrue(app.navigationBars["食用紀錄"].waitForExistence(timeout: 3))
        app.staticTexts["Milk"].firstMatch.tap()
        app.buttons["放回冰箱"].tap()
        XCTAssertTrue(app.staticTexts["還沒有食用紀錄\n標記為「已食用」的食材會出現在這裡"].waitForExistence(timeout: 3))

        app.navigationBars["食用紀錄"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: 3), "back in the active inventory")
    }
}
