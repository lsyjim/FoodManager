import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5I: 每週餐桌, inventory matching, shortages, 購物清單, persistence and backups.
final class MealPlanningTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 10, 28) } // a Wednesday
    private var analyzer: MealPlanAnalyzer { MealPlanAnalyzer(calendar: calendar, evaluator: FoodReminderEvaluator(calendar: calendar)) }

    private func food(_ name: String, _ quantity: Decimal, _ unit: String, expires: Date? = nil, fridge: UUID = UUID(),
                      consumed: Date? = nil) -> FoodItem {
        FoodItem(id: UUID(), name: name, categoryID: "other", quantity: quantity, unit: unit, storedAt: date(2026, 10, 20),
                 expirationDate: expires, storageReminderDays: nil, fridgeID: fridge, compartmentID: UUID(),
                 createdAt: date(2026, 10, 20), updatedAt: date(2026, 10, 20), consumedAt: consumed)
    }

    private func ingredient(_ name: String, _ quantity: Decimal? = nil, _ unit: String? = nil, linked: UUID? = nil) -> PlannedIngredient {
        var item = PlannedIngredient(name: name, unit: unit, linkedFoodID: linked)
        item.quantity = quantity
        return item
    }

    private func dish(_ title: String, _ day: Int, _ meal: MealType = .breakfast, _ ingredients: [PlannedIngredient] = [],
                      completed: Bool = false) -> PlannedDish {
        PlannedDish(day: DayKey(date(2026, 10, day), calendar: calendar), meal: meal, title: title, isCompleted: completed, ingredients: ingredients)
    }

    // MARK: Week

    func testWeekRunsMondayToSundayAcrossBoundaries() {
        var week = MealWeek()
        week.calendar.timeZone = calendar.timeZone
        let days = week.days(of: date(2026, 11, 1)) // Sunday
        XCTAssertEqual(days.map { week.calendar.component(.day, from: $0) }, [26, 27, 28, 29, 30, 31, 1])
        XCTAssertEqual(week.calendar.component(.weekday, from: days[0]), 2, "Monday first")
        XCTAssertEqual(week.days(of: date(2026, 10, 26)).first, days.first, "Monday is its own week's start")
        let next = week.week(date(2026, 10, 28), offsetBy: 1)
        XCTAssertEqual(week.calendar.dateComponents([.month, .day], from: next), DateComponents(month: 11, day: 2))
        XCTAssertEqual(week.calendar.dateComponents([.month, .day], from: week.week(date(2026, 10, 28), offsetBy: -1)), DateComponents(month: 10, day: 19))
    }

    func testDayKeysSortAndRoundTrip() {
        let key = DayKey(date(2026, 2, 5), calendar: calendar)
        XCTAssertEqual(key.value, "2026-02-05")
        XCTAssertLessThan(DayKey("2026-02-05"), DayKey("2026-10-01"))
        XCTAssertEqual(key.date(calendar: calendar).map { calendar.component(.day, from: $0) }, 5)
        XCTAssertFalse(DayKey("2026-13-40").isValid || DayKey("bad").isValid)
    }

    // MARK: Matching and quantities

    func testNameMatchingIsExactAfterNormalisationPlusFixedSynonyms() {
        XCTAssertEqual(IngredientNaming.key(" 雞蛋 "), IngredientNaming.key("蛋"))
        XCTAssertEqual(IngredientNaming.key("ＭＩＬＫ"), IngredientNaming.key("milk"))
        XCTAssertEqual(IngredientNaming.key("蕃茄"), IngredientNaming.key("番茄"))
        XCTAssertNotEqual(IngredientNaming.key("雞肉"), IngredientNaming.key("雞蛋"), "unrelated names never merge")
        XCTAssertNotEqual(IngredientNaming.key("牛奶糖"), IngredientNaming.key("牛奶"))
    }

    func testEnoughInventoryIsReady() {
        let eggs = food("雞蛋", 6, "顆")
        let plan = [dish("炒蛋", 28, .dinner, [ingredient("蛋", 3, "顆")])]
        XCTAssertEqual(analyzer.analyze(dishes: plan, inventory: [eggs], now: now).values.first?.status, .ready)
    }

    func testShortageIsExact() {
        let plan = [dish("蛋餅", 28, .dinner, [ingredient("雞蛋", 5, "顆")])]
        let info = analyzer.analyze(dishes: plan, inventory: [food("雞蛋", 2, "顆")], now: now).values.first!
        XCTAssertEqual(info.status, .insufficient(missing: 3))
        XCTAssertEqual(info.detail, "還缺 3 顆")
    }

    func testIncompatibleUnitsAreUnknownNotSummed() {
        let plan = [dish("咖哩", 29, .dinner, [ingredient("馬鈴薯", 300, "g")])]
        let info = analyzer.analyze(dishes: plan, inventory: [food("馬鈴薯", 2, "包"), food("馬鈴薯", 1, "公斤")], now: now).values.first!
        XCTAssertEqual(info.status, .ready, "1 公斤 converts exactly to 1000 g; 包 is never counted")
        let packsOnly = analyzer.analyze(dishes: plan, inventory: [food("馬鈴薯", 2, "包")], now: now).values.first!
        XCTAssertEqual(packsOnly.status, .unknown)
        XCTAssertEqual(IngredientNaming.convert(2, from: "kg", to: "公克"), 2000)
        XCTAssertNil(IngredientNaming.convert(1, from: "包", to: "顆"))
        XCTAssertNil(IngredientNaming.convert(1, from: "kg", to: "ml"))
    }

    func testDemandAcrossDaysIsAllocatedOnce() {
        // Monday 2 eggs, Tuesday 3 eggs, 4 in the fridge: the second meal is short by 1 — never both "ready".
        let monday = dish("早餐 A", 28, .breakfast, [ingredient("雞蛋", 2, "顆")])
        let tuesday = dish("早餐 B", 29, .breakfast, [ingredient("雞蛋", 3, "顆")])
        let result = analyzer.analyze(dishes: [tuesday, monday], inventory: [food("雞蛋", 4, "顆")], now: now)
        XCTAssertEqual(result[monday.ingredients[0].id]?.status, .ready, "earlier meal first")
        XCTAssertEqual(result[tuesday.ingredients[0].id]?.status, .insufficient(missing: 1))
        let shortages = analyzer.shortages(dishes: [monday, tuesday], inventory: [food("雞蛋", 4, "顆")], now: now)
        XCTAssertEqual(shortages.map(\.quantity), [1])
    }

    func testExpiredFoodIsNeverUsableAndExpiringSoonIsHighlighted() {
        let expired = food("牛奶", 2, "瓶", expires: date(2026, 10, 20))
        let plan = [dish("奶茶", 28, .lunch, [ingredient("牛奶", 1, "瓶")])]
        let info = analyzer.analyze(dishes: plan, inventory: [expired], now: now).values.first!
        XCTAssertEqual(info.status, .needToBuy(missing: 1))
        XCTAssertEqual(info.expiredMatches.count, 1)
        XCTAssertTrue(info.detail.contains("已過期"))

        let soon = food("牛奶", 2, "瓶", expires: date(2026, 10, 29))
        let fresh = analyzer.analyze(dishes: plan, inventory: [soon], now: now).values.first!
        XCTAssertEqual(fresh.status, .ready)
        XCTAssertTrue(fresh.expiringSoon)
        let noDate = analyzer.analyze(dishes: plan, inventory: [food("牛奶", 2, "瓶")], now: now).values.first!
        XCTAssertEqual(noDate.status, .ready, "missing expiry information doesn't block usage")
        XCTAssertFalse(noDate.expiringSoon)
    }

    func testLinkedFoodIsTheOnlySupplyAndMissingLinksFallBack() {
        let mine = food("雞蛋", 1, "顆"), other = food("雞蛋", 10, "顆")
        let linked = dish("煎蛋", 28, .dinner, [ingredient("雞蛋", 2, "顆", linked: mine.id)])
        XCTAssertEqual(analyzer.analyze(dishes: [linked], inventory: [mine, other], now: now).values.first?.status, .insufficient(missing: 1))
        let gone = analyzer.analyze(dishes: [linked], inventory: [other], now: now).values.first!
        XCTAssertEqual(gone.status, .ready, "falls back to name matching")
        XCTAssertTrue(gone.linkedMissing)
    }

    func testChecklistIngredientsAndSkippedDishes() {
        let plan = [dish("沙拉", 28, .lunch, [ingredient("生菜")]), dish("昨天", 27, .lunch, [ingredient("雞蛋", 2, "顆")]),
                    dish("完成", 28, .dinner, [ingredient("雞蛋", 2, "顆")], completed: true)]
        let result = analyzer.analyze(dishes: plan, inventory: [food("雞蛋", 1, "顆")], now: now)
        XCTAssertEqual(result[plan[0].ingredients[0].id]?.status, .needToBuy(missing: nil))
        XCTAssertEqual(result[plan[1].ingredients[0].id]?.status, .notChecked, "past dishes aren't checked")
        XCTAssertEqual(result[plan[2].ingredients[0].id]?.status, .notChecked, "completed dishes don't consume supply")
    }

    func testFridgeScopeIsTheGivenInventoryOnly() {
        let home = UUID(), office = UUID()
        let inventory = [food("雞蛋", 2, "顆", fridge: home), food("雞蛋", 3, "顆", fridge: office)]
        let plan = [dish("蛋", 28, .dinner, [ingredient("雞蛋", 5, "顆")])]
        XCTAssertEqual(analyzer.analyze(dishes: plan, inventory: inventory.filter { $0.fridgeID == home }, now: now).values.first?.status,
                       .insufficient(missing: 3))
        XCTAssertEqual(analyzer.analyze(dishes: plan, inventory: inventory, now: now).values.first?.status, .ready, "所有冰箱 adds both")
        let consumed = food("雞蛋", 9, "顆", consumed: date(2026, 10, 25))
        XCTAssertEqual(analyzer.analyze(dishes: plan, inventory: [consumed], now: now).values.first?.status, .needToBuy(missing: 5))
    }

    // MARK: Shopping merge

    func testShortagesAreNeverDuplicatedOrOverwritten() {
        let shortage = MealShortage(key: MealPlanAnalyzer.shortageKey(name: "雞蛋", unit: "顆"), name: "雞蛋", categoryID: nil,
                                    quantity: 3, unit: "顆", dishTitles: ["蛋餅"])
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: []), .add)
        var generated = ShoppingItem(name: "雞蛋", unit: "顆", sourceKey: shortage.key)
        generated.quantity = 1
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: [generated]), .update(itemID: generated.id))
        generated.quantity = 3
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: [generated]), .alreadyListed(edited: false))
        var edited = generated
        edited.quantity = 1
        edited.isUserEdited = true
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: [edited]), .alreadyListed(edited: true))
        let manual = ShoppingItem(name: "蛋", unit: "顆")
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: [manual]), .alreadyListed(edited: true), "the user's own item counts")
        var bought = generated
        bought.isPurchased = true
        XCTAssertEqual(ShoppingMerge.action(for: shortage, pending: [bought]), .add,
                       "merging only looks at pending items; bought ones are supply in the analyzer instead")
    }

    private func boughtItem(_ name: String, _ quantity: Decimal?, _ unit: String?, stored: Bool = false) -> ShoppingItem {
        var item = ShoppingItem(name: name, unit: unit, isPurchased: true, purchasedAt: now)
        item.quantity = quantity
        if stored { item.storedFoodID = UUID() }
        return item
    }

    func testBoughtItemsCountAsSupplySoTheyAreNotOfferedAgain() {
        let omelette = dish("蛋餅", 28, .dinner, [ingredient("雞蛋", 3, "顆")])
        let soup = dish("蛋花湯", 29, .dinner, [ingredient("蛋", 2, "顆")])
        let fridge = [food("雞蛋", 1, "顆")]

        let all = analyzer.analyze(dishes: [omelette, soup], inventory: fridge, bought: [boughtItem("雞蛋", 4, "顆")], now: now)
        let first = all[omelette.ingredients[0].id]!, second = all[soup.ingredients[0].id]!
        XCTAssertEqual(first.status, .ready, "1 in the fridge first, then 2 of the 4 bought")
        XCTAssertTrue(first.coveredByBought)
        XCTAssertEqual(first.detail, "含已買到、還沒放進冰箱的")
        XCTAssertEqual(second.status, .ready, "the other 2 bought, same synonym")
        XCTAssertTrue(analyzer.shortages(dishes: [omelette, soup], inventory: fridge, bought: [boughtItem("雞蛋", 4, "顆")], now: now).isEmpty)

        let partly = analyzer.shortages(dishes: [omelette, soup], inventory: fridge, bought: [boughtItem("雞蛋", 2, "顆")], now: now)
        XCTAssertEqual(partly.map(\.quantity), [2], "only what is still missing")

        let noAmount = analyzer.analyze(dishes: [omelette], inventory: [], bought: [boughtItem("雞蛋", nil, nil)], now: now)
        XCTAssertEqual(noAmount[omelette.ingredients[0].id]?.status, .ready, "bought without an amount covers it")
        let otherUnit = analyzer.analyze(dishes: [omelette], inventory: [], bought: [boughtItem("雞蛋", 1, "盒")], now: now)
        XCTAssertEqual(otherUnit[omelette.ingredients[0].id]?.status, .ready, "a 盒 can't be compared, but it was bought for this")
        let checklist = dish("沙拉", 28, .lunch, [ingredient("生菜")])
        XCTAssertEqual(analyzer.analyze(dishes: [checklist], inventory: [], bought: [boughtItem("生菜", nil, nil)], now: now)
            .values.first?.status, .ready)
    }

    func testOnlyBoughtItemsNotYetInAFridgeAreSupply() {
        let omelette = dish("蛋餅", 28, .dinner, [ingredient("雞蛋", 3, "顆")])
        var pending = boughtItem("雞蛋", 3, "顆")
        pending.isPurchased = false
        let stored = boughtItem("雞蛋", 3, "顆", stored: true) // already counted as the food record it became
        let result = analyzer.analyze(dishes: [omelette], inventory: [], bought: [pending, stored], now: now)
        XCTAssertEqual(result[omelette.ingredients[0].id]?.status, .needToBuy(missing: 3))
        XCTAssertEqual(result[omelette.ingredients[0].id]?.coveredByBought, false)
    }

    func testQuickAddLineIsSplitIntoNameQuantityAndUnit() {
        XCTAssertTrue(ShoppingQuickEntry.parse("牛奶 2 瓶")! == ("牛奶", 2, "瓶"))
        XCTAssertTrue(ShoppingQuickEntry.parse("雞蛋3")! == ("雞蛋", 3, nil))
        XCTAssertTrue(ShoppingQuickEntry.parse(" 可樂 1.5 L ")! == ("可樂", Decimal(string: "1.5"), "L"))
        XCTAssertTrue(ShoppingQuickEntry.parse("豆腐")! == ("豆腐", nil, nil))
        XCTAssertTrue(ShoppingQuickEntry.parse("2")! == ("2", nil, nil), "a number alone is a name")
        XCTAssertNil(ShoppingQuickEntry.parse("   "))
    }

    // MARK: Store

    private func makeStore() throws -> (SwiftDataMealPlanStore, ModelContainer) {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        return (SwiftDataMealPlanStore(container: container), container)
    }

    func testDishesSaveEditDeleteAndKeepIDs() throws {
        let (store, _) = try makeStore()
        var first = dish("番茄炒蛋", 28, .dinner, [ingredient("番茄", 2, "顆"), ingredient("雞蛋", 3, "顆")])
        var second = dish("湯", 28, .dinner)
        second.sortOrder = 1
        try store.save([first, second])
        XCTAssertEqual(try store.dishes(from: first.day, through: first.day).map(\.title), ["番茄炒蛋", "湯"], "several dishes per meal")
        first.title = "番茄炒蛋（少油）"
        first.ingredients.removeLast()
        try store.save(first)
        let reloaded = try XCTUnwrap(try store.allDishes().first { $0.id == first.id })
        XCTAssertEqual(reloaded.title, "番茄炒蛋（少油）")
        XCTAssertEqual(reloaded.ingredients.map(\.id), [first.ingredients[0].id], "ingredient IDs stable")
        try store.deleteDish(id: second.id)
        XCTAssertEqual(try store.allDishes().count, 1)
        XCTAssertThrowsError(try store.deleteDish(id: second.id))
    }

    func testInvalidDishIsRejectedAndNothingSaved() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.save(dish("  ", 28))) { XCTAssertEqual($0 as? MealPlanStoreError, .invalid("請輸入菜名")) }
        XCTAssertThrowsError(try store.save([dish("好", 28), dish("壞", 28, .lunch, [ingredient("", 1, "顆")])]))
        XCTAssertTrue(try store.allDishes().isEmpty, "all or nothing")
    }

    func testCopyCreatesAnIndependentDish() throws {
        let (store, _) = try makeStore()
        let original = dish("咖哩", 28, .dinner, [ingredient("馬鈴薯", 2, "顆")], completed: true)
        let copy = original.copied(to: DayKey("2026-10-30"), meal: .lunch, sortOrder: 0)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.ingredients[0].id, original.ingredients[0].id)
        XCTAssertEqual(copy.ingredients[0].quantity, 2)
        XCTAssertFalse(copy.isCompleted)
        try store.save([original, copy])
        var edited = copy
        edited.title = "雞肉咖哩"
        try store.save(edited)
        XCTAssertEqual(Set(try store.allDishes().map(\.title)), ["咖哩", "雞肉咖哩"])
    }

    func testCompletingAMealNeverTouchesTheFridge() throws {
        let session = try AppBootstrap.makeSession(container: try SwiftDataFridgeStore.makeContainer(inMemory: true), mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore()).get()
        let fridge = session.loadResult.fridge
        let eggs = FoodItem(id: UUID(), name: "雞蛋", categoryID: "egg", quantity: 6, unit: "顆", storedAt: .now, fridgeID: fridge.id,
                            compartmentID: fridge.cabinetCompartments[0].id, createdAt: .now, updatedAt: .now)
        try session.foodStore.upsert(eggs)
        let store = SwiftDataMealPlanStore(container: session.container)
        var meal = PlannedDish(day: DayKey(Date()), meal: .dinner, title: "蛋包飯", ingredients: [ingredient("雞蛋", 3, "顆", linked: eggs.id)])
        try store.save(meal)
        meal.isCompleted = true
        try store.save(meal)
        meal.isCompleted = false
        try store.save(meal)
        meal.isCompleted = true
        try store.save(meal)
        XCTAssertEqual(try session.foodStore.activeItems(fridgeID: fridge.id).first?.quantity, 6, "no deduction, ever")
    }

    func testShoppingItemsPersistAndValidate() throws {
        let (store, _) = try makeStore()
        var item = ShoppingItem(name: "牛奶", unit: "瓶")
        item.quantity = 2
        try store.save(item)
        item.isPurchased = true
        item.isUserEdited = true
        try store.save(item)
        XCTAssertEqual(try store.shoppingItems(), [item])
        var bad = ShoppingItem(name: "x")
        bad.quantityText = "abc"
        XCTAssertThrowsError(try store.save(bad))
        XCTAssertThrowsError(try store.save(ShoppingItem(name: "")))
        try store.deleteShoppingItem(id: item.id)
        XCTAssertTrue(try store.shoppingItems().isEmpty)
    }

    func testDataSurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meal-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = dish("便當", 30, .lunch, [ingredient("白飯")])
        do {
            let store = SwiftDataMealPlanStore(container: try SwiftDataFridgeStore.makeContainer(url: url))
            try store.save(planned)
            try store.save(ShoppingItem(name: "海苔"))
        }
        let reopened = SwiftDataMealPlanStore(container: try SwiftDataFridgeStore.makeContainer(url: url))
        XCTAssertEqual(try reopened.allDishes(), [planned])
        XCTAssertEqual(try reopened.shoppingItems().map(\.name), ["海苔"])
        XCTAssertNil(try SwiftDataFridgeStore.makeContainer(url: url).configurations.first?.cloudKitContainerIdentifier, "local only")
    }

    // MARK: Backup

    private func backupService(_ container: ModelContainer, defaults: UserDefaults) -> BackupService {
        BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                      preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: InMemoryFridgeSelectionStore()),
                      recoveryDirectory: nil, applicationVersion: "test")
    }

    func testBackupCarriesMealPlansAndShoppingList() throws {
        let defaults = UserDefaults(suiteName: "meal-backup-\(UUID().uuidString)")!
        let (store, container) = try makeStore()
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        let planned = dish("滷肉飯", 31, .dinner, [ingredient("豬絞肉", 300, "g")])
        try store.save(planned)
        try store.save(ShoppingItem(name: "醬油"))
        let backup = try backupService(container, defaults: defaults).makeBackup()
        XCTAssertEqual(backup.formatVersion, 3)
        let data = try BackupCoding.encoder().encode(backup)
        let decoded = try BackupValidator.decode(data)
        XCTAssertEqual(decoded.mealPlanner?.dishes, [planned])

        let (otherStore, other) = try makeStore()
        try backupService(other, defaults: defaults).restore(decoded)
        XCTAssertEqual(try otherStore.allDishes(), [planned])
        XCTAssertEqual(try otherStore.shoppingItems().map(\.name), ["醬油"])
    }

    func testOlderBackupsImportAndKeepTheCurrentPlan() throws {
        let defaults = UserDefaults(suiteName: "meal-old-\(UUID().uuidString)")!
        let (store, container) = try makeStore()
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        let keep = dish("保留", 30, .dinner)
        try store.save(keep)
        var old = try backupService(container, defaults: defaults).makeBackup()
        old.formatVersion = 2
        old.mealPlanner = nil
        let decoded = try BackupValidator.decode(try BackupCoding.encoder().encode(old))
        XCTAssertNil(decoded.mealPlanner)
        try backupService(container, defaults: defaults).restore(decoded)
        XCTAssertEqual(try store.allDishes(), [keep], "a file without meal plans leaves them as they are")
    }

    func testCorruptMealDataInABackupIsRejected() throws {
        let defaults = UserDefaults(suiteName: "meal-bad-\(UUID().uuidString)")!
        let (_, container) = try makeStore()
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        var backup = try backupService(container, defaults: defaults).makeBackup()
        backup.mealPlanner = BackupMealPlanner(dishes: [dish("", 30)], shoppingItems: [])
        XCTAssertThrowsError(try BackupValidator.validate(backup)) { XCTAssertEqual($0 as? BackupError, .invalidMealPlanner) }
    }

    // MARK: Home and ads

    func testHomeCountsTodaysMealSlots() {
        let today = DayKey("2026-10-28")
        let dishes = [PlannedDish(day: today, meal: .breakfast, title: "a"), PlannedDish(day: today, meal: .breakfast, title: "b"),
                      PlannedDish(day: today, meal: .dinner, title: "c"), PlannedDish(day: DayKey("2026-10-29"), meal: .lunch, title: "d")]
        XCTAssertEqual(HomeShortcutCounts.mealsPlannedToday(dishes, today: today), 2)
        XCTAssertEqual(HomeShortcutCounts.mealText(0), "今天還沒安排")
        XCTAssertEqual(HomeShortcutCounts.mealText(3), "今天 3 餐已規劃")
        XCTAssertEqual(HomeShortcutCounts.shoppingText(4), "4 項待購買")
        XCTAssertEqual(HomeShortcutCounts.shoppingText(0), "清單是空的")
    }

    func testMealPlannerAdPlacementOnlyOnThePlanner() {
        for screen in AppScreen.allCases {
            XCTAssertEqual(AdPlacement.mealPlannedInterstitial.isAllowed(on: screen), screen == .mealPlanner)
        }
        XCTAssertFalse(AdPlacement.allCases.contains { $0.isAllowed(on: .foodEditor) }, "never while editing food")
    }
}
