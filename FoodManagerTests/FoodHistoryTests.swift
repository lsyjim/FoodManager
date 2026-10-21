import SwiftData
import UIKit
import XCTest
@testable import FoodManager

/// Phase 3.1: history, restore, permanent delete, favorites, recent suggestions, fast & continuous entry,
/// statistics and notification sync.
@MainActor
final class FoodHistoryTests: XCTestCase {
    private var fridge: Fridge!
    private var container: ModelContainer!
    private var flaky: FlakyFoodStore!
    private var inventory: FoodInventoryService!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private var shelf: UUID { fridge.cabinetCompartments[0].id }
    private var freezer: UUID { fridge.cabinetCompartments[1].id }

    override func setUpWithError() throws {
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[1].storageType = .frozen
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        flaky = FlakyFoodStore(base: SwiftDataFoodStore(container: container))
        inventory = makeInventory(flaky)
    }

    private func makeInventory(_ store: FoodStore) -> FoodInventoryService {
        FoodInventoryService(store: store, fridgeID: fridge.id, compartments: { [unowned self] in self.fridge.allCompartments },
                             now: { [unowned self] in self.clock })
    }

    @discardableResult
    private func add(_ name: String, in compartment: UUID? = nil, category: String = "other", unit: String = "個",
                     quantity: Decimal = 1, expiresIn days: Int? = nil) throws -> FoodItem {
        var draft = FoodDraft(compartmentID: compartment ?? shelf, now: clock)
        draft.name = name
        draft.categoryID = category
        draft.unit = unit
        draft.quantity = quantity
        draft.expirationDate = days.map { clock.addingTimeInterval(Double($0) * 86_400) }
        return try inventory.add(draft)
    }

    private func consume(_ item: FoodItem, after seconds: TimeInterval) throws {
        clock += seconds
        try inventory.markConsumed(item.id)
    }

    // 1–3: history filtering, sorting, searching
    func testHistoryShowsOnlyConsumedNewestFirstAndIsSearchable() throws {
        let milk = try add("牛奶")
        let eggs = try add("雞蛋")
        try add("起司") // still active
        try consume(milk, after: 60)
        try consume(eggs, after: 60)
        let history = try inventory.historyItems()
        XCTAssertEqual(history.map(\.name), ["雞蛋", "牛奶"], "newest consumption first")
        XCTAssertTrue(history.allSatisfy { $0.consumedAt != nil })
        XCTAssertEqual(inventory.items.map(\.name), ["起司"], "consumed food is not in the active inventory")
        XCTAssertEqual(try inventory.searchHistory("奶").map(\.name), ["牛奶"])
        XCTAssertEqual(try inventory.searchHistory("  ").count, 2)
    }

    func testConsumedFoodNotInReminderCounts() throws {
        let old = try add("過期品", expiresIn: -3)
        try inventory.markConsumed(old.id)
        let summary = DashboardAggregator().summary(items: inventory.items, compartments: fridge.allCompartments, filter: .all, now: clock)
        XCTAssertEqual(summary.expiredCount, 0)
        XCTAssertEqual(summary.itemCount, 0)
    }

    func testHistoryReadFailureThrows() throws {
        try consume(try add("牛奶"), after: 1)
        flaky.failReads = true
        XCTAssertThrowsError(try inventory.historyItems(), "a failed read is reported, not shown as empty history")
    }

    // 4, 7: restore preserves identity, no duplicates
    func testRestorePreservesRecordAndOriginalCompartment() throws {
        let fish = try add("鮭魚", in: freezer, category: "seafood", unit: "片", quantity: Decimal(string: "2.5")!, expiresIn: -1)
        try consume(fish, after: 60)
        clock += 60
        let restored = try inventory.restore(fish.id)
        XCTAssertEqual(restored.id, fish.id)
        XCTAssertNil(restored.consumedAt)
        XCTAssertEqual(restored.compartmentID, freezer, "original compartment, never moved silently")
        XCTAssertEqual([restored.name, restored.categoryID, restored.unit], ["鮭魚", "seafood", "片"])
        XCTAssertEqual(restored.quantity, Decimal(string: "2.5"))
        XCTAssertEqual(restored.expirationDate, fish.expirationDate, "expired date is kept, shown as expired")
        XCTAssertEqual(inventory.itemCount(in: freezer), 1)
        XCTAssertTrue(try inventory.historyItems().isEmpty)
        XCTAssertThrowsError(try inventory.restore(fish.id)) { XCTAssertEqual($0 as? FoodValidationError, .alreadyActive) }
        XCTAssertEqual(inventory.items.count, 1, "no duplicate record")
        let reminders = FoodReminderEvaluator().reminders(for: restored, now: clock)
        XCTAssertTrue(reminders.contains(.expired))
    }

    // 5: missing compartment requires a choice
    func testRestoreWithMissingCompartmentRequiresDestination() throws {
        let item = try add("醬油", in: fridge.doorCompartments[0].id)
        try consume(item, after: 1)
        let lostID = fridge.doorCompartments[0].id
        fridge.doorCompartments.removeAll { $0.id == lostID }
        XCTAssertThrowsError(try inventory.restore(item.id)) {
            XCTAssertEqual($0 as? FoodValidationError, .restoreNeedsCompartment)
        }
        XCTAssertThrowsError(try inventory.restore(item.id, to: UUID())) {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentNotFound)
        }
        XCTAssertTrue(inventory.items.isEmpty, "nothing restored until the user picks a valid place")
        XCTAssertEqual(try inventory.restore(item.id, to: shelf).compartmentID, shelf)
    }

    func testRestoreFailureKeepsHistory() throws {
        let item = try add("牛奶")
        try consume(item, after: 1)
        flaky.failWrites = true
        XCTAssertThrowsError(try inventory.restore(item.id))
        flaky.failWrites = false
        XCTAssertEqual(try inventory.historyItems().map(\.id), [item.id])
        XCTAssertTrue(inventory.items.isEmpty)
    }

    // 6: permanent deletion
    func testPermanentDeleteRemovesFromHistoryAndStorage() throws {
        let item = try add("剩菜")
        try consume(item, after: 1)
        flaky.failDeletes = true
        XCTAssertThrowsError(try inventory.delete(item.id))
        XCTAssertEqual(try inventory.historyItems().count, 1, "failed delete changes nothing")
        flaky.failDeletes = false
        try inventory.delete(item.id)
        XCTAssertTrue(try inventory.historyItems().isEmpty)
        XCTAssertTrue(try SwiftDataFoodStore(container: container).consumedItems(fridgeID: fridge.id).isEmpty)
    }

    // 8–10: favorite foods
    func testFavoriteFoodsOrderDedupeUnpinAndPersistence() throws {
        let suite = "FoodHistoryTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UserDefaultsFavoriteFoodStore(defaults: UserDefaults(suiteName: suite)!)
        var favorites = store.load()
        let milk = try favorites.pin(FoodTemplate(name: "牛奶", categoryID: "dairy", unit: "瓶", preferredCompartmentID: shelf))
        try favorites.pin(FoodTemplate(name: "雞蛋", categoryID: "eggs", unit: "顆"))
        try favorites.pin(FoodTemplate(name: "豆腐", categoryID: "soy-products", unit: "盒"))
        XCTAssertThrowsError(try favorites.pin(FoodTemplate(name: " 牛奶 ", categoryID: "dairy", unit: "瓶"))) {
            XCTAssertEqual($0 as? FavoriteFoodError, .duplicate)
        }
        XCTAssertThrowsError(try favorites.pin(FoodTemplate(name: "  ", categoryID: "other", unit: "個")))
        favorites.move(from: 2, to: 0)
        XCTAssertEqual(favorites.templates.map(\.name), ["豆腐", "牛奶", "雞蛋"], "manual order only")
        store.save(favorites)

        let relaunched = UserDefaultsFavoriteFoodStore(defaults: UserDefaults(suiteName: suite)!).load()
        XCTAssertEqual(relaunched, favorites)
        XCTAssertEqual(relaunched.templates[1].id, milk.id, "stable IDs survive relaunch")
        var edited = relaunched
        edited.unpin(milk.id)
        XCTAssertEqual(edited.templates.map(\.name), ["豆腐", "雞蛋"])
    }

    func testFavoriteLimit() throws {
        var favorites = FavoriteFoods()
        for i in 0..<FavoriteFoods.maxCount { try favorites.pin(FoodTemplate(name: "食材\(i)", categoryID: "other", unit: "個")) }
        XCTAssertThrowsError(try favorites.pin(FoodTemplate(name: "多一個", categoryID: "other", unit: "個"))) {
            XCTAssertEqual($0 as? FavoriteFoodError, .limitReached)
        }
    }

    // 11–12: recent suggestions with normalized de-duplication
    func testRecentSuggestionsFromActiveAndHistoryWithDedupe() throws {
        let first = try add("Milk", category: "dairy", unit: "瓶")
        clock += 10
        try add("雞蛋", category: "eggs", unit: "顆")
        clock += 10
        try consume(first, after: 10)
        clock += 10
        try add(" milk ", category: "beverages", unit: "罐") // same normalized name, newest
        let suggestions = inventory.recentFoodSuggestions()
        XCTAssertEqual(suggestions.map(\.name), ["milk", "雞蛋"], "one entry per normalized name, newest first")
        XCTAssertEqual(suggestions[0].categoryID, "beverages", "uses the latest record")
        XCTAssertEqual(suggestions[0].unit, "罐")
        XCTAssertNil(suggestions[0].preferredCompartmentID)
        XCTAssertEqual(FoodNameKey.normalize("ＭＩＬＫ"), FoodNameKey.normalize("milk"))
        XCTAssertEqual(RecentFoodSuggestions.filter(suggestions, query: "MI").map(\.name), ["milk"])
    }

    // 13: fast entry populates only name, category, unit (+ valid preferred compartment)
    func testApplyingTemplateFillsOnlyRelevantFields() {
        var draft = FoodDraft(now: clock)
        draft.quantity = 3
        draft.expirationDate = clock
        draft.storageReminderDays = 4
        draft.apply(FoodTemplate(name: "優格", categoryID: "dairy", unit: "杯", preferredCompartmentID: freezer),
                    validCompartmentIDs: Set(fridge.allCompartments.map(\.id)))
        XCTAssertEqual([draft.name, draft.categoryID, draft.unit], ["優格", "dairy", "杯"])
        XCTAssertEqual(draft.compartmentID, freezer)
        XCTAssertEqual(draft.quantity, 3, "quantity untouched")
        XCTAssertEqual(draft.expirationDate, clock, "dates untouched")
        XCTAssertEqual(draft.storageReminderDays, 4)

        var fromCompartment = FoodDraft(compartmentID: shelf, now: clock)
        fromCompartment.apply(FoodTemplate(name: "a", categoryID: "bogus", unit: "個", preferredCompartmentID: UUID()),
                              validCompartmentIDs: Set(fridge.allCompartments.map(\.id)))
        XCTAssertEqual(fromCompartment.compartmentID, shelf, "invalid preferred compartments are ignored")
        XCTAssertEqual(fromCompartment.categoryID, FoodCategoryCatalog.otherID, "unknown category falls back to 其他")
    }

    // 14: continuous entry
    func testContinuousEntryResetsTheRightFields() throws {
        let editor = FoodEditorViewController(mode: .add(compartmentID: freezer), inventory: inventory,
                                              compartments: fridge.allCompartments)
        editor.loadViewIfNeeded()
        let storedAt = clock.addingTimeInterval(-86_400 * 2)
        editor.draft.name = "水餃"
        editor.draft.categoryID = "frozen-foods"
        editor.draft.unit = "包"
        editor.draft.quantity = 3
        editor.draft.storedAt = storedAt
        editor.draft.expirationDate = clock
        editor.draft.storageReminderDays = 30
        XCTAssertEqual(editor.submitSave(), .success)
        editor.prepareNextEntry()
        XCTAssertEqual(editor.draft.name, "")
        XCTAssertEqual(editor.draft.quantity, 1)
        XCTAssertEqual(editor.draft.categoryID, FoodCategoryCatalog.otherID)
        XCTAssertNil(editor.draft.expirationDate)
        XCTAssertNil(editor.draft.storageReminderDays)
        XCTAssertEqual(editor.draft.compartmentID, freezer, "compartment kept")
        XCTAssertEqual(editor.draft.storedAt, storedAt, "storedAt kept")
        XCTAssertEqual(inventory.items.count, 1)
    }

    // 15 & 7: failed save keeps the form; no duplicates from repeated taps
    func testFailedSaveKeepsFormAndRepeatedSaveDoesNotDuplicate() throws {
        let editor = FoodEditorViewController(mode: .add(compartmentID: shelf), inventory: inventory,
                                              compartments: fridge.allCompartments)
        editor.loadViewIfNeeded()
        editor.draft.name = "豆漿"
        flaky.failWrites = true
        guard case .failure = editor.submitSave() else { return XCTFail() }
        XCTAssertEqual(editor.draft.name, "豆漿", "input kept after failure")
        XCTAssertTrue(inventory.items.isEmpty)
        flaky.failWrites = false
        XCTAssertEqual(editor.submitSave(), .success)
        XCTAssertFalse(editor.isSubmitting)
        XCTAssertEqual(inventory.items.count, 1)
    }

    // 16–18: notification sync
    func testNotificationsFollowConsumeRestoreAndPermanentDelete() async throws {
        let client = FakeNotificationClient()
        let coordinator = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(),
                                                  planner: NotificationPlanner(calendar: calendar),
                                                  now: { [unowned self] in self.clock },
                                                  snapshot: { [unowned self] in (self.inventory.items, self.fridge.allCompartments) })
        let milk = try add("牛奶", expiresIn: 5)
        await coordinator.reschedule()
        let id = PlannedNotification.identifier(foodID: milk.id, kind: .expiration)
        XCTAssertNotNil(client.pending[id])

        try inventory.markConsumed(milk.id)
        await coordinator.reschedule()
        XCTAssertNil(client.pending[id], "consumed food has no pending notification")

        try inventory.restore(milk.id)
        await coordinator.reschedule()
        XCTAssertNotNil(client.pending[id], "restored food is rescheduled")

        try inventory.markConsumed(milk.id)
        try inventory.delete(milk.id)
        await coordinator.reschedule()
        XCTAssertTrue(client.pending.isEmpty, "permanently deleted food has nothing pending")
    }

    // 19: statistics
    func testHistoryStatisticsUseRealConsumedRecords() throws {
        let day: TimeInterval = 86_400
        for (name, days) in [("牛奶", 2.0), ("牛奶", 4.0), ("Milk", 1.0), ("雞蛋", 6.0)] {
            let item = try add(name)
            try consume(item, after: days * day)
            clock -= days * day
        }
        try add("沒吃的") // active: not counted
        let stats = HistoryStatistics(history: try inventory.historyItems(), calendar: calendar)
        XCTAssertEqual(stats.consumedCount, 4)
        XCTAssertEqual(stats.topNames.first, .init(name: "牛奶", count: 2))
        XCTAssertEqual(stats.averageStorageDays ?? 0, 13.0 / 4, accuracy: 0.01)
        XCTAssertNil(HistoryStatistics(history: []).averageStorageDays)
        var noDate = try add("x")
        noDate.consumedAt = nil
        XCTAssertEqual(HistoryStatistics(history: [noDate]).consumedCount, 0, "records without consumedAt are ignored")
        XCTAssertNotNil(FoodHistoryViewController.statisticsText(stats))
    }

    // 20: persistence after relaunch
    func testHistoryAndRestoreSurviveRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.store")
        let first = makeInventory(SwiftDataFoodStore(container: try SwiftDataFridgeStore.makeContainer(url: url)))
        var draft = FoodDraft(compartmentID: shelf, now: clock)
        draft.name = "布丁"
        let pudding = try first.add(draft)
        try first.markConsumed(pudding.id)

        let second = makeInventory(SwiftDataFoodStore(container: try SwiftDataFridgeStore.makeContainer(url: url)))
        XCTAssertEqual(try second.historyItems().map(\.id), [pudding.id])
        try second.restore(pudding.id)

        let third = makeInventory(SwiftDataFoodStore(container: try SwiftDataFridgeStore.makeContainer(url: url)))
        XCTAssertEqual(third.items.map(\.id), [pudding.id])
        XCTAssertTrue(try third.historyItems().isEmpty)
    }
}
