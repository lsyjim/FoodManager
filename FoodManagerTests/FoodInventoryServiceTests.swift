import SwiftData
import XCTest
@testable import FoodManager

/// Food CRUD, quantities, movement, search, counts, delete safety and persistence (real SwiftData stores).
final class FoodInventoryServiceTests: XCTestCase {
    private var fridge: Fridge!
    private var inventory: FoodInventoryService!
    private var container: ModelContainer!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    private var chilled: Compartment { fridge.cabinetCompartments[0] }
    private var frozen: Compartment { fridge.cabinetCompartments[1] }
    private var door: Compartment { fridge.doorCompartments[0] }

    override func setUpWithError() throws {
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[1].storageType = .frozen
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        inventory = makeInventory(container: container)
    }

    private func makeInventory(container: ModelContainer) -> FoodInventoryService {
        FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                             compartments: { [unowned self] in self.fridge.allCompartments },
                             now: { [unowned self] in self.clock })
    }

    private func draft(_ name: String, in compartment: UUID?, quantity: Decimal = 1, category: String = "other") -> FoodDraft {
        var draft = FoodDraft(compartmentID: compartment, now: clock)
        draft.name = name
        draft.quantity = quantity
        draft.categoryID = category
        return draft
    }

    // 1 & 6: creating food in a compartment
    func testAddCreatesRecordWithDefaultsAndAssignment() throws {
        let defaults = FoodDraft(now: clock)
        XCTAssertEqual(defaults.quantity, 1)
        XCTAssertEqual(defaults.unit, "個")
        XCTAssertEqual(defaults.categoryID, FoodCategoryCatalog.otherID)
        XCTAssertNil(defaults.expirationDate)
        XCTAssertNil(defaults.storageReminderDays)

        let item = try inventory.add(draft("  牛奶 ", in: chilled.id, quantity: Decimal(string: "1.5")!, category: "dairy"))
        XCTAssertEqual(item.name, "牛奶")
        XCTAssertEqual(item.compartmentID, chilled.id)
        XCTAssertEqual(item.fridgeID, fridge.id)
        XCTAssertEqual(item.createdAt, clock)
        XCTAssertEqual(inventory.items(in: chilled.id).map(\.id), [item.id])
    }

    func testAddRequiresValidNameAndCompartment() {
        XCTAssertThrowsError(try inventory.add(draft("   ", in: chilled.id))) {
            XCTAssertEqual($0 as? FoodValidationError, .emptyName)
        }
        XCTAssertThrowsError(try inventory.add(draft("蛋", in: nil))) {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentRequired)
        }
        XCTAssertThrowsError(try inventory.add(draft("蛋", in: UUID()))) {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentNotFound)
        }
        var bad = draft("蛋", in: chilled.id)
        bad.storageReminderDays = 0
        XCTAssertThrowsError(try inventory.add(bad)) { XCTAssertEqual($0 as? FoodValidationError, .invalidReminderDays) }
        XCTAssertTrue(inventory.items.isEmpty)
    }

    // 2: editing
    func testUpdateKeepsIdentityAndCreationDate() throws {
        let item = try inventory.add(draft("雞蛋", in: chilled.id, quantity: 6))
        clock += 3600
        var edit = FoodDraft(item: item)
        edit.name = "土雞蛋"
        edit.unit = "顆"
        edit.expirationDate = clock
        edit.storageReminderDays = 7
        let updated = try inventory.update(item.id, with: edit)
        XCTAssertEqual(updated.id, item.id)
        XCTAssertEqual(updated.createdAt, item.createdAt)
        XCTAssertEqual(updated.updatedAt, clock)
        XCTAssertEqual(updated.name, "土雞蛋")
        XCTAssertEqual(updated.storageReminderDays, 7)
        XCTAssertEqual(inventory.item(id: item.id), updated)
    }

    // 3: consume / delete
    func testMarkConsumedRemovesFromActiveInventory() throws {
        let item = try inventory.add(draft("優格", in: chilled.id))
        try inventory.markConsumed(item.id)
        XCTAssertNil(inventory.item(id: item.id))
        XCTAssertEqual(inventory.itemCount(in: chilled.id), 0)
    }

    func testDeleteRemovesRecord() throws {
        let item = try inventory.add(draft("錯誤輸入", in: chilled.id))
        try inventory.delete(item.id)
        XCTAssertTrue(inventory.items.isEmpty)
        XCTAssertThrowsError(try inventory.delete(item.id))
    }

    // 4 & 5: quantities
    func testDecimalQuantitiesAndQuickAdjustments() throws {
        let milk = try inventory.add(draft("牛奶", in: chilled.id, quantity: Decimal(string: "1.5")!))
        XCTAssertEqual(try inventory.adjustQuantity(milk.id, by: 1).quantity, Decimal(string: "2.5"))
        XCTAssertEqual(try inventory.adjustQuantity(milk.id, by: -2).quantity, Decimal(string: "0.5"))
        // Reaching zero is never saved silently: the UI must offer "mark as consumed".
        XCTAssertThrowsError(try inventory.adjustQuantity(milk.id, by: -1)) {
            XCTAssertEqual($0 as? FoodValidationError, .zeroQuantity)
        }
        XCTAssertEqual(inventory.item(id: milk.id)?.quantity, Decimal(string: "0.5"))
    }

    func testNegativeAndZeroQuantitiesAreRejected() throws {
        XCTAssertThrowsError(try inventory.add(draft("蘋果", in: chilled.id, quantity: -1))) {
            XCTAssertEqual($0 as? FoodValidationError, .negativeQuantity)
        }
        let apple = try inventory.add(draft("蘋果", in: chilled.id, quantity: 2))
        var edit = FoodDraft(item: apple)
        edit.quantity = -0.5
        XCTAssertThrowsError(try inventory.update(apple.id, with: edit)) {
            XCTAssertEqual($0 as? FoodValidationError, .negativeQuantity)
        }
        edit.quantity = 0
        XCTAssertThrowsError(try inventory.update(apple.id, with: edit)) {
            XCTAssertEqual($0 as? FoodValidationError, .zeroQuantity)
        }
        XCTAssertEqual(inventory.item(id: apple.id)?.quantity, 2)
    }

    // 7: moving
    func testMovePreservesIDAndDatesAndUpdatesCounts() throws {
        let meat = try inventory.add(draft("豬肉", in: chilled.id, category: "meat"))
        clock += 86_400
        try inventory.move(meat.id, to: frozen.id)
        let moved = try XCTUnwrap(inventory.item(id: meat.id))
        XCTAssertEqual(moved.storedAt, meat.storedAt, "storedAt is never reset by a move")
        XCTAssertEqual(moved.createdAt, meat.createdAt)
        XCTAssertEqual(inventory.itemCount(in: chilled.id), 0)
        XCTAssertEqual(inventory.itemCount(in: frozen.id), 1)
        XCTAssertThrowsError(try inventory.move(meat.id, to: UUID()))
    }

    // 18 & 19: counts are records, icons one per record
    func testCompartmentCountIsRecordCountNotQuantitySum() throws {
        try inventory.add(draft("雞蛋", in: chilled.id, quantity: 12, category: "eggs"))
        try inventory.add(draft("牛奶", in: chilled.id, quantity: 2, category: "dairy"))
        try inventory.add(draft("高麗菜", in: chilled.id, quantity: 1, category: "leafy-greens"))
        try inventory.add(draft("菠菜", in: chilled.id, quantity: 1, category: "leafy-greens"))
        let summary = inventory.contentSummary(for: chilled.id)
        XCTAssertEqual(summary.itemCount, 4)
        XCTAssertEqual(Set(summary.icons.map(\.foodID)).count, 4, "records sharing a category still get their own icon")
        XCTAssertEqual(summary.icons.filter { $0.categoryID == "leafy-greens" }.count, 2)
    }

    func testIconOrderIsDeterministic() throws {
        clock = Date(timeIntervalSince1970: 2_000)
        let b = try inventory.add(draft("B", in: chilled.id))
        clock = Date(timeIntervalSince1970: 1_000)
        let a = try inventory.add(draft("A", in: chilled.id))
        XCTAssertEqual(inventory.contentSummary(for: chilled.id).icons.map(\.foodID), [a.id, b.id], "oldest stored first")
    }

    // 20: missing compartment references
    func testFoodWithMissingCompartmentIsKeptAndVisible() throws {
        let item = try inventory.add(draft("醬油", in: door.id, category: "condiments"))
        let lostID = door.id
        fridge.doorCompartments.removeAll { $0.id == lostID } // simulate a layout that lost the compartment
        inventory.reload()
        XCTAssertEqual(inventory.itemsWithMissingCompartment.map(\.id), [item.id])
        XCTAssertEqual(inventory.search("").map(\.id), [item.id])
        let summary = DashboardAggregator().summary(items: inventory.items, compartments: fridge.allCompartments,
                                                    filter: .all, now: clock)
        XCTAssertEqual(summary.itemCount, 1, "never silently dropped from 全部")
        // Editing requires choosing a valid compartment again.
        XCTAssertThrowsError(try inventory.update(item.id, with: FoodDraft(item: item))) {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentNotFound)
        }
        var fixed = FoodDraft(item: item)
        fixed.compartmentID = chilled.id
        XCTAssertEqual(try inventory.update(item.id, with: fixed).compartmentID, chilled.id)
    }

    // 21: delete safety
    func testOccupiedCompartmentCannotBeDeleted() throws {
        try inventory.add(draft("起司", in: chilled.id))
        try inventory.add(draft("奶油", in: chilled.id))
        let editor = FridgeLayoutEditor(fridge: fridge, occupancy: inventory)
        XCTAssertThrowsError(try editor.delete(chilled.id)) {
            XCTAssertEqual($0 as? LayoutEditError, .compartmentOccupied(itemCount: 2))
            XCTAssertEqual(($0 as? LayoutEditError)?.message, "此隔層還有 2 項食材，請先移到其他隔層")
        }
        XCTAssertNoThrow(try editor.delete(frozen.id), "empty compartments can still be deleted")
        XCTAssertEqual(inventory.itemCount(in: chilled.id), 2, "no cascade delete")
    }

    func testCompartmentCanBeDeletedAfterFoodIsMovedOrConsumed() throws {
        let a = try inventory.add(draft("起司", in: chilled.id))
        let b = try inventory.add(draft("奶油", in: chilled.id))
        try inventory.move(a.id, to: frozen.id)
        try inventory.markConsumed(b.id)
        XCTAssertNoThrow(try FridgeLayoutEditor(fridge: fridge, occupancy: inventory).delete(chilled.id))
    }

    // 23: dashboard follows changes
    func testDashboardReflectsAddMoveConsumeAndReclassification() throws {
        func totals() -> (all: Int?, chilled: Int?, frozen: Int?) {
            let provider = InventoryDashboardProvider(items: inventory.items, compartments: fridge.allCompartments,
                                                      aggregator: DashboardAggregator(), now: clock)
            return (provider.summary(for: .all).itemCount, provider.summary(for: .refrigerated).itemCount,
                    provider.summary(for: .frozen).itemCount)
        }
        let fish = try inventory.add(draft("鮭魚", in: chilled.id, category: "seafood"))
        try inventory.add(draft("可樂", in: door.id, category: "beverages"))
        XCTAssertTrue(totals() == (2, 1, 0))
        try inventory.move(fish.id, to: frozen.id)
        XCTAssertTrue(totals() == (2, 0, 1))
        fridge.cabinetCompartments[1].storageType = .refrigerated // reclassify the compartment, not the food
        XCTAssertTrue(totals() == (2, 1, 0))
        try inventory.markConsumed(fish.id)
        XCTAssertTrue(totals() == (1, 0, 0))
    }

    func testMutationsPostChangeNotification() throws {
        let posted = expectation(forNotification: .foodInventoryDidChange, object: inventory)
        try inventory.add(draft("豆腐", in: chilled.id))
        wait(for: [posted], timeout: 1)
    }

    // 24: search
    func testSearchByNameIsCaseInsensitiveAndPartial() throws {
        try inventory.add(draft("Greek Yogurt", in: chilled.id))
        try inventory.add(draft("鮮奶", in: chilled.id))
        try inventory.add(draft("奶油", in: door.id))
        XCTAssertEqual(inventory.search("yog").map(\.name), ["Greek Yogurt"])
        XCTAssertEqual(Set(inventory.search("奶").map(\.name)), ["鮮奶", "奶油"])
        XCTAssertEqual(inventory.search("  ").count, 3)
        XCTAssertTrue(inventory.search("西瓜").isEmpty)
    }

    // 22: persistence across relaunch
    func testFoodPersistsAcrossRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("food.store")

        let first = makeInventory(container: try SwiftDataFridgeStore.makeContainer(url: url))
        var withDates = draft("牛奶", in: chilled.id, quantity: Decimal(string: "1.5")!, category: "dairy")
        withDates.unit = "公升"
        withDates.expirationDate = clock + 86_400 * 3
        withDates.storageReminderDays = 5
        let milk = try first.add(withDates)
        let eaten = try first.add(draft("香蕉", in: chilled.id, category: "fruits"))
        try first.markConsumed(eaten.id)

        let relaunched = makeInventory(container: try SwiftDataFridgeStore.makeContainer(url: url))
        XCTAssertEqual(relaunched.items, [milk], "all fields round-trip, including the decimal quantity")
    }

    // 17 (persistence): adding the food entity keeps existing fridge layouts
    func testPhase11StoreOpensWithFoodSchemaWithoutLosingLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.store")

        // Phase 1.1 schema: fridge only.
        do {
            let schema = Schema([FridgeRecord.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(old)
            context.insert(FridgeRecord(id: fridge.id, name: "我的冰箱", templateID: fridge.templateID,
                                        lastDoorStateRaw: DoorState.open.rawValue, layoutData: try StoredLayout.encode(fridge)))
            try context.save()
        }

        let container = try SwiftDataFridgeStore.makeContainer(url: url)
        let loaded = try SwiftDataFridgeStore(container: container).loadOrCreateFridge()
        XCTAssertEqual(loaded, Fridge(id: fridge.id, name: "我的冰箱", templateID: fridge.templateID, lastDoorState: .open,
                                      cabinetCompartments: fridge.cabinetCompartments, doorCompartments: fridge.doorCompartments))
        let foods = makeInventory(container: container)
        XCTAssertTrue(foods.items.isEmpty)
        XCTAssertNoThrow(try foods.add(draft("牛奶", in: chilled.id)))
    }
}
