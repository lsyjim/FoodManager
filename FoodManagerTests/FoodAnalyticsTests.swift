import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5G: calendar events, statistics and their screens, from real records in in-memory stores.
final class FoodAnalyticsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.firstWeekday = 1
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func food(_ name: String, category: String = "dairy", stored: Date, expires: Date? = nil, reminder: Int? = nil,
                      consumed: Date? = nil, fridge: UUID = UUID(), compartment: UUID = UUID(), id: UUID = UUID()) -> FoodItem {
        FoodItem(id: id, name: name, categoryID: category, quantity: 1, unit: "個", storedAt: stored, expirationDate: expires,
                 storageReminderDays: reminder, fridgeID: fridge, compartmentID: compartment, createdAt: stored, updatedAt: stored,
                 consumedAt: consumed)
    }

    private var model: FoodCalendarModel { FoodCalendarModel(calendar: calendar) }
    private var stats: FoodStatistics { FoodStatistics(calendar: calendar, evaluator: FoodReminderEvaluator(calendar: calendar)) }

    // MARK: Month grid

    func testMonthGridStartsOnTheFirstWeekdayAndCoversWholeWeeks() {
        let grid = model.monthGrid(for: date(2026, 10, 15))
        XCTAssertEqual(grid.count % 7, 0)
        XCTAssertEqual(grid.prefix(4).compactMap { $0 }.count, 0, "Oct 1 2026 is a Thursday")
        XCTAssertEqual(grid[4].map { calendar.component(.day, from: $0) }, 1)
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
    }

    func testLeapYearFebruary() {
        XCTAssertEqual(model.monthGrid(for: date(2028, 2, 10)).compactMap { $0 }.count, 29)
        XCTAssertEqual(model.monthGrid(for: date(2027, 2, 10)).compactMap { $0 }.count, 28)
    }

    func testMonthNavigationCrossesYears() {
        let december = model.month(date(2026, 12, 20), offsetBy: 1)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: december), DateComponents(year: 2027, month: 1, day: 1))
        let back = model.month(date(2027, 1, 5), offsetBy: -1)
        XCTAssertEqual(calendar.dateComponents([.year, .month], from: back), DateComponents(year: 2026, month: 12))
    }

    // MARK: Events

    func testStoredExpirationAndReminderEventsLandOnTheirDays() {
        let milk = food("牛奶", stored: date(2026, 10, 3), expires: date(2026, 10, 10), reminder: 5)
        let events = model.eventsByDay(items: [milk], month: date(2026, 10, 1))
        XCTAssertEqual(events[calendar.startOfDay(for: date(2026, 10, 3))]?.map(\.kind), [.stored])
        XCTAssertEqual(events[calendar.startOfDay(for: date(2026, 10, 10))]?.map(\.kind), [.expiration])
        XCTAssertEqual(events[calendar.startOfDay(for: date(2026, 10, 8))]?.map(\.kind), [.storageReminder], "stored + 5 days")
        XCTAssertEqual(events.values.flatMap { $0 }.count, 3, "no event repeated after expiry")
    }

    func testReminderDayMatchesTheReminderRule() {
        let item = food("豆腐", stored: date(2026, 10, 3, 23), reminder: 2)
        let event = model.events(for: item).first { $0.kind == .storageReminder }!
        let evaluator = FoodReminderEvaluator(calendar: calendar)
        XCTAssertTrue(evaluator.isStorageReminderDue(item, now: event.day))
        XCTAssertFalse(evaluator.isStorageReminderDue(item, now: event.day.addingTimeInterval(-1)))
    }

    func testSeveralEventsOnOneDaySortedAndKindsDistinct() {
        let day = date(2026, 10, 12)
        let items = [food("B 優格", stored: day), food("A 起司", stored: day), food("C 牛奶", stored: date(2026, 10, 1), expires: day)]
        let events = model.eventsByDay(items: items, month: day)[calendar.startOfDay(for: day)]!
        XCTAssertEqual(events.map(\.item.name), ["C 牛奶", "A 起司", "B 優格"], "expiration first, then by name")
        XCTAssertEqual(FoodCalendarModel.kinds(events), [.expiration, .stored], "one dot per kind, not per food")
    }

    func testConsumedFoodKeepsOnlyItsHistoricalStoredEvent() {
        let eaten = food("吐司", stored: date(2026, 10, 2), expires: date(2026, 10, 20), reminder: 3, consumed: date(2026, 10, 4))
        let events = model.events(for: eaten)
        XCTAssertEqual(events.map(\.kind), [.stored])
        XCTAssertTrue(events[0].isHistorical, "never shown as an active future reminder")
    }

    func testMissingOptionalDatesGiveOnlyTheStoredEvent() {
        XCTAssertEqual(model.events(for: food("鹽", stored: date(2026, 10, 2))).map(\.kind), [.stored])
    }

    func testDayBoundariesFollowTheCalendarTimeZone() {
        // 23:30 Taipei on Oct 31 is still October there (it is already Nov 1 in UTC+9 and later).
        let late = food("宵夜", stored: date(2026, 10, 31, 23).addingTimeInterval(30 * 60))
        let october = model.eventsByDay(items: [late], month: date(2026, 10, 1))
        XCTAssertNotNil(october[calendar.startOfDay(for: date(2026, 10, 31))])
        XCTAssertTrue(model.eventsByDay(items: [late], month: date(2026, 11, 1)).isEmpty)
    }

    func testEventsOutsideTheMonthAreNotIncludedAndNeverDuplicated() {
        let item = food("米", stored: date(2026, 9, 30), expires: date(2026, 11, 2))
        XCTAssertTrue(model.eventsByDay(items: [item], month: date(2026, 10, 1)).isEmpty)
        let twice = model.eventsByDay(items: [item, item], month: date(2026, 9, 1))
        XCTAssertEqual(twice.values.flatMap { $0 }.count, 2, "each record's own event only")
    }

    // MARK: Scope

    func testFridgeAndTemperatureFiltering() {
        let fridgeA = UUID(), fridgeB = UUID()
        let cold = Compartment(id: UUID(), parentZoneID: .cabinet, name: "上層", type: .shelf, storageType: .refrigerated, sortOrder: 0,
                               normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5))
        let frozen = Compartment(id: UUID(), parentZoneID: .cabinet, name: "冷凍", type: .drawer, storageType: .frozen, sortOrder: 1,
                                 normalizedFrame: NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let items = [food("A", stored: date(2026, 10, 1), fridge: fridgeA, compartment: cold.id),
                     food("B", stored: date(2026, 10, 1), fridge: fridgeA, compartment: frozen.id),
                     food("C", stored: date(2026, 10, 1), fridge: fridgeB, compartment: cold.id)]
        let data = FoodAnalyticsData(items: items, compartments: [cold.id: cold, frozen.id: frozen], fridgeNames: [fridgeA: "家", fridgeB: "公司"])
        XCTAssertEqual(data.filtered(FoodAnalyticsScope(fridgeIDs: [fridgeA])).map(\.name), ["A", "B"])
        XCTAssertEqual(data.filtered(FoodAnalyticsScope(fridgeIDs: [fridgeA, fridgeB], storage: .refrigerated)).map(\.name), ["A", "C"])
        XCTAssertEqual(data.filtered(FoodAnalyticsScope(fridgeIDs: [fridgeA], storage: .frozen)).map(\.name), ["B"])
        XCTAssertEqual(data.location(of: items[2], showFridge: true), "公司 · 櫃內 · 上層")
    }

    // MARK: Statistics

    func testSummaryUsesTheReminderRules() {
        let now = date(2026, 10, 25)
        let items = [food("過期", stored: date(2026, 10, 1), expires: date(2026, 10, 20)),
                     food("快到期", stored: date(2026, 10, 1), expires: date(2026, 10, 27)),
                     food("新鮮", stored: date(2026, 10, 1), expires: date(2026, 11, 30)),
                     food("吃掉了", stored: date(2026, 10, 1), consumed: date(2026, 10, 24)),
                     food("很久以前吃掉", stored: date(2026, 1, 1), consumed: date(2026, 2, 1))]
        XCTAssertEqual(stats.summary(items: items, period: .week, now: now),
                       InventorySummary(active: 3, expired: 1, expiringSoon: 1, consumedInPeriod: 1))
        XCTAssertEqual(stats.summary(items: items, period: .halfYear, now: now).consumedInPeriod, 1, "February is outside 6 months ending October")
    }

    func testDailyActivityBuckets() {
        let now = date(2026, 10, 25)
        let items = [food("a", stored: date(2026, 10, 25, 8)), food("b", stored: date(2026, 10, 19), consumed: date(2026, 10, 25)),
                     food("old", stored: date(2026, 10, 18))]
        let week = stats.activity(items: items, period: .week, now: now)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.label, "10/19")
        XCTAssertEqual(week.last.map { ($0.added, $0.consumed) }.map { [$0.0, $0.1] }, [1, 1])
        XCTAssertEqual(week.first?.added, 1)
        XCTAssertEqual(week.reduce(0) { $0 + $1.added }, 2, "10/18 is outside the last 7 days")
        XCTAssertEqual(stats.activity(items: items, period: .month, now: now).count, 30)
    }

    func testMonthlyActivityBuckets() {
        let now = date(2026, 10, 25)
        let items = [food("a", stored: date(2026, 5, 3)), food("b", stored: date(2026, 10, 1), consumed: date(2026, 10, 2)),
                     food("too old", stored: date(2026, 4, 30))]
        let months = stats.activity(items: items, period: .halfYear, now: now)
        XCTAssertEqual(months.map(\.label), ["5月", "6月", "7月", "8月", "9月", "10月"])
        XCTAssertEqual(months.first?.added, 1)
        XCTAssertEqual(months.last?.added, 1)
        XCTAssertEqual(months.last?.consumed, 1)
        XCTAssertEqual(months.reduce(0) { $0 + $1.added }, 2)
    }

    func testCategorySharesCountRecordsAndAddUpToOne() {
        var items = (0..<3).map { food("奶\($0)", category: "dairy", stored: date(2026, 10, 1)) }
        items += [food("肉", category: "meat", stored: date(2026, 10, 1)),
                  food("舊分類", category: "legacy-unknown", stored: date(2026, 10, 1)),
                  food("其他", category: FoodCategoryCatalog.otherID, stored: date(2026, 10, 1)),
                  food("吃掉的", category: "meat", stored: date(2026, 10, 1), consumed: date(2026, 10, 2))]
        let shares = stats.categoryShares(items: items)
        XCTAssertEqual(shares.map(\.category.id), ["dairy", FoodCategoryCatalog.otherID, "meat"], "unknown merges into 其他, no duplicates")
        XCTAssertEqual(shares.map(\.count), [3, 2, 1], "active records only, never quantities")
        XCTAssertEqual(shares.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertTrue(stats.categoryShares(items: []).isEmpty)
    }

    func testLargeInventoryStaysExact() {
        let categories = FoodCategoryCatalog.all.map(\.id)
        let items = (0..<5_000).map { food("\($0)", category: categories[$0 % categories.count], stored: date(2026, 10, 1)) }
        let shares = stats.categoryShares(items: items)
        XCTAssertEqual(shares.count, categories.count)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.count }, 5_000)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
    }

    func testAverageStorageDaysUsesValidPairsOnly() {
        let now = date(2026, 10, 25)
        let items = [food("a", stored: date(2026, 10, 20), consumed: date(2026, 10, 24)),
                     food("b", stored: date(2026, 10, 22), consumed: date(2026, 10, 24)),
                     food("bad", stored: date(2026, 10, 24), consumed: date(2026, 10, 20)),
                     food("active", stored: date(2026, 10, 1))]
        XCTAssertEqual(stats.averageStorageDays(items: items, period: .week, now: now), 3)
        XCTAssertNil(stats.averageStorageDays(items: [items[3]], period: .week, now: now))
    }

    func testChartSelectionModels() {
        let category = CategoryChartModel()
        category.shares = [CategoryShare(category: FoodCategoryCatalog.category(id: "dairy"), count: 3, fraction: 0.75),
                           CategoryShare(category: FoodCategoryCatalog.category(id: "meat"), count: 1, fraction: 0.25)]
        category.select(cumulative: 3)
        XCTAssertEqual(category.selectedID, "meat")
        category.select(cumulative: 3)
        XCTAssertNil(category.selectedID, "tapping again clears")
        category.toggle("dairy")
        XCTAssertEqual(category.selected?.count, 3)
        // A tap at 3 o'clock on the ring is a quarter of the way round.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(CategoryDonutView.cumulativeValue(at: CGPoint(x: 195, y: 100), in: frame, total: 4), 1)
        XCTAssertNil(CategoryDonutView.cumulativeValue(at: CGPoint(x: 100, y: 100), in: frame, total: 4), "the hole selects nothing")

        let activity = ActivityChartModel()
        let day = date(2026, 10, 20)
        activity.buckets = [ActivityBucket(start: calendar.startOfDay(for: day), label: "10/20", added: 2, consumed: 1)]
        activity.select(near: day)
        XCTAssertEqual(activity.selected?.added, 2)
    }

    // MARK: Screens and refresh

    private func session() throws -> AppSession {
        try AppBootstrap.makeSession(container: try SwiftDataFridgeStore.makeContainer(inMemory: true), mode: .inMemoryForTesting,
                                     selection: InMemoryFridgeSelectionStore()).get()
    }

    @MainActor
    func testStatisticsRefreshAfterFoodChanges() throws {
        let session = try session()
        let fridge = session.loadResult.fridge
        let screen = FoodStatisticsViewController(loader: FoodAnalyticsLoader(directory: session.directory, foodStore: session.foodStore),
                                                  currentFridgeID: fridge.id)
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.summary.active, 0)
        XCTAssertTrue(screen.categories.shares.isEmpty)
        try session.foodStore.upsert(food("牛奶", stored: .now, fridge: fridge.id, compartment: fridge.cabinetCompartments[0].id))
        NotificationCenter.default.post(name: .foodInventoryDidChange, object: nil)
        XCTAssertEqual(screen.summary.active, 1)
        XCTAssertEqual(screen.categories.shares.first?.count, 1)
        XCTAssertFalse(screen.activity.isEmpty)
    }

    @MainActor
    func testCalendarShowsTodaysEventsAndNavigates() throws {
        let session = try session()
        let fridge = session.loadResult.fridge
        let now = Date()
        try session.foodStore.upsert(food("吐司", stored: now, fridge: fridge.id, compartment: fridge.cabinetCompartments[0].id))
        let screen = FoodCalendarViewController(loader: FoodAnalyticsLoader(directory: session.directory, foodStore: session.foodStore),
                                                currentFridgeID: fridge.id, now: { now })
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.selectedEvents.map(\.item.name), ["吐司"])
        screen.showMonth(offset: 1)
        XCTAssertTrue(screen.selectedEvents.isEmpty)
        screen.jumpToToday()
        XCTAssertEqual(screen.selectedEvents.map(\.kind), [.stored])
    }

    func testLoadFailureIsAnErrorNotAnEmptyCalendar() throws {
        final class FailingFoodStore: FoodStore {
            func activeItems(fridgeID: UUID) throws -> [FoodItem] { throw FoodStoreError.notFound }
            func consumedItems(fridgeID: UUID) throws -> [FoodItem] { [] }
            func upsert(_ item: FoodItem) throws {}
            func delete(id: UUID) throws {}
            func unplacedActiveItems(knownFridgeIDs: Set<UUID>) throws -> [FoodItem] { [] }
        }
        let session = try session()
        XCTAssertThrowsError(try FoodAnalyticsLoader(directory: session.directory, foodStore: FailingFoodStore()).load()) {
            XCTAssertEqual($0 as? FoodAnalyticsLoadError, .unreadable)
        }
    }
}
