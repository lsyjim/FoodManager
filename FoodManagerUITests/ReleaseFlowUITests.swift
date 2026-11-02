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
        XCTAssertTrue(element("settings.exportBackup").waitForExistence(timeout: 3))
        XCTAssertTrue(element("settings.importBackup").exists)
        XCTAssertFalse(element("settings.upgrade").exists, "no purchase UI in 1.0")
        XCTAssertFalse(element("settings.restore").exists)
        // Phase 5E: no automatic iCloud sync switch anywhere (temporary UI-test data never offers iCloud backups).
        XCTAssertFalse(element("settings.cloudSync").exists)
        XCTAssertFalse(app.staticTexts["iCloud 自動同步"].exists)
    }

    func testCalendarAndStatisticsOpenFromSettingsWithoutAds() throws {
        element("home.settings").tap()
        XCTAssertTrue(element("settings.calendar").waitForExistence(timeout: 3))
        element("settings.calendar").tap()
        XCTAssertTrue(element("calendar").waitForExistence(timeout: 3))
        XCTAssertTrue(element("calendar.today").exists)
        XCTAssertTrue(app.staticTexts["這天沒有食材紀錄"].waitForExistence(timeout: 3), "empty day, no mock data")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("settings.statistics").waitForExistence(timeout: 3))
        element("settings.statistics").tap()
        XCTAssertTrue(element("statistics").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["冰箱裡目前沒有食材。"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["GADInterstitialAdView"].exists, "no ad when opening statistics")
    }

    func testMealPlannerAndShoppingListFromHome() throws {
        // Both shortcuts are on the home screen (not in Settings).
        XCTAssertTrue(element("home.mealPlanner").waitForExistence(timeout: 3))
        XCTAssertTrue(element("home.shoppingList").exists)
        XCTAssertTrue(element("home.mealPlanner").label.contains("今天還沒安排"))

        element("home.mealPlanner").tap()
        XCTAssertTrue(element("mealPlanner").waitForExistence(timeout: 3))
        // Section-header buttons are reported twice by accessibility (and as not hittable), so tap the + of 晚餐 where
        // it is on screen, like a finger does.
        let addDinner = app.buttons.matching(identifier: "mealPlanner.add.dinner").firstMatch
        XCTAssertTrue(addDinner.waitForExistence(timeout: 3))
        addDinner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let title = app.textFields["dishEditor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Omelette")
        element("dishEditor.addIngredient").tap()
        let name = app.textFields["ingredientEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Egg")
        app.textFields["ingredientEditor.quantity"].tap()
        app.textFields["ingredientEditor.quantity"].typeText("3")
        app.textFields["ingredientEditor.unit"].tap()
        app.textFields["ingredientEditor.unit"].typeText("pcs")
        element("ingredientEditor.done").tap()
        XCTAssertTrue(app.staticTexts["需要購買 · 還缺 3 pcs"].waitForExistence(timeout: 3), "nothing in the fridge yet")
        element("dishEditor.save").tap()
        XCTAssertTrue(app.staticTexts["Omelette"].waitForExistence(timeout: 3))

        // Shortages → shopping list (preview, then add).
        element("mealPlanner.addToShopping").tap()
        XCTAssertTrue(element("shoppingPreview").waitForExistence(timeout: 3))
        let previewRow = app.cells["shoppingPreview.row"].firstMatch
        XCTAssertTrue(previewRow.waitForExistence(timeout: 3))
        XCTAssertTrue(previewRow.staticTexts["Egg 3 pcs"].exists, "the whole name typed is kept")
        element("shoppingPreview.add").tap()
        XCTAssertTrue(element("mealPlanner").waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(element("home.mealPlanner").waitForExistence(timeout: 3))
        XCTAssertTrue(element("home.mealPlanner").label.contains("今天 1 餐已規劃"))
        XCTAssertTrue(element("home.shoppingList").label.contains("1 項待購買"))
        element("home.shoppingList").tap()
        XCTAssertTrue(element("shoppingList").waitForExistence(timeout: 3))
        // Quick add keeps the keyboard up for the next item.
        let quickAdd = app.textFields["shoppingList.quickAdd"]
        quickAdd.tap()
        quickAdd.typeText("Milk 2 bottles\n")
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["2 bottles"].exists)

        // Check off Egg, undo the "mis-tap", then check it off for real.
        let checkEgg = app.buttons["標記買到「Egg」"]
        XCTAssertTrue(checkEgg.waitForExistence(timeout: 3))
        checkEgg.tap()
        XCTAssertTrue(element("shoppingList.undo").waitForExistence(timeout: 3))
        element("shoppingList.undo").tap()
        XCTAssertTrue(checkEgg.waitForExistence(timeout: 3), "back in 待購買")
        checkEgg.tap()
        XCTAssertTrue(element("shoppingList.putIntoFridge").waitForExistence(timeout: 3))
        XCTAssertFalse(element("shoppingList.shortages").exists, "bought, so the planner doesn't ask for it again")
        element("shoppingList.putIntoFridge").tap()
        XCTAssertTrue(app.navigationBars["新增食材"].waitForExistence(timeout: 3), "the usual food editor, prefilled")
        XCTAssertEqual(app.textFields["food.name"].value as? String, "Egg")
    }
}
