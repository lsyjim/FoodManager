import UIKit
import XCTest
@testable import FoodManager

/// 12–15 & 25: reminder center filtering, ordering, de-duplication, consistency with the dashboard.
final class ReminderCenterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!
    private var fridge: Fridge!
    private var builder: ReminderCenterBuilder { ReminderCenterBuilder(evaluator: FoodReminderEvaluator(calendar: calendar)) }

    override func setUp() {
        super.setUp()
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[1].storageType = .frozen
    }

    private var chilled: UUID { fridge.cabinetCompartments[0].id }
    private var frozen: UUID { fridge.cabinetCompartments[1].id }
    private var door: UUID { fridge.doorCompartments[0].id }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    private func item(_ name: String, in compartment: UUID, expiresIn: Int? = nil, storedDaysAgo: Int = 0,
                      remindAfter: Int? = nil) -> FoodItem {
        FoodItem(id: UUID(), name: name, categoryID: "other", quantity: 1, unit: "個", storedAt: day(-storedDaysAgo),
                 expirationDate: expiresIn.map(day), storageReminderDays: remindAfter, fridgeID: fridge.id,
                 compartmentID: compartment, createdAt: now, updatedAt: now)
    }

    private func entries(_ items: [FoodItem], _ storage: StorageFilter = .all, _ kind: ReminderKindFilter = .all) -> [ReminderEntry] {
        builder.entries(items: items, compartments: fridge.allCompartments, storage: storage, kind: kind, now: now)
    }

    func testRefrigeratorAndFreezerFiltering() {
        let items = [item("牛奶", in: chilled, expiresIn: 1), item("水餃", in: frozen, expiresIn: -1),
                     item("醬油", in: door, expiresIn: 0), item("遺失", in: UUID(), expiresIn: 2)]
        XCTAssertEqual(entries(items, .refrigerated).map(\.item.name), ["牛奶"])
        XCTAssertEqual(entries(items, .frozen).map(\.item.name), ["水餃"])
        XCTAssertEqual(Set(entries(items, .all).map(\.item.name)), ["牛奶", "水餃", "醬油", "遺失"],
                       "unspecified and missing compartments appear under 全部")
        XCTAssertEqual(entries(items).first { $0.item.name == "遺失" }?.locationText, "位置不存在")
    }

    func testOrderingByUrgency() {
        let items = [item("存放久", in: chilled, storedDaysAgo: 20, remindAfter: 7),
                     item("明天", in: chilled, expiresIn: 1),
                     item("過期1天", in: chilled, expiresIn: -1),
                     item("今天", in: chilled, expiresIn: 0),
                     item("過期5天", in: chilled, expiresIn: -5),
                     item("存放更久", in: chilled, storedDaysAgo: 40, remindAfter: 7)]
        XCTAssertEqual(entries(items).map(\.item.name), ["過期5天", "過期1天", "今天", "明天", "存放更久", "存放久"])
    }

    func testOneEntryPerFoodWithAllStatuses() {
        let both = item("冷凍水餃", in: frozen, expiresIn: -1, storedDaysAgo: 30, remindAfter: 14)
        let result = entries([both])
        XCTAssertEqual(result.count, 1, "no duplicate rows")
        XCTAssertEqual(result[0].kinds, [.expired, .storedTooLong])
        XCTAssertEqual(result[0].statusTexts, ["已過期 1 天", "已存放 30 天"])
        XCTAssertEqual(entries([both], .all, .expired).count, 1)
        XCTAssertEqual(entries([both], .all, .storedTooLong).count, 1)
        XCTAssertEqual(entries([both], .all, .expiringSoon).count, 0)
    }

    func testCountsMatchDashboard() {
        let items = [item("a", in: chilled, expiresIn: 0), item("b", in: frozen, expiresIn: -2, storedDaysAgo: 9, remindAfter: 3),
                     item("c", in: door, storedDaysAgo: 5, remindAfter: 5), item("d", in: chilled)]
        for storage in StorageFilter.allCases {
            let counts = builder.counts(items: items, compartments: fridge.allCompartments, storage: storage, now: now)
            let dashboard = DashboardAggregator(evaluator: FoodReminderEvaluator(calendar: calendar))
                .summary(items: items, compartments: fridge.allCompartments, filter: storage, now: now)
            XCTAssertEqual(counts[.expiringSoon], dashboard.expiringSoonCount, "\(storage)")
            XCTAssertEqual(counts[.expired], dashboard.expiredCount, "\(storage)")
            XCTAssertEqual(counts[.storedTooLong], dashboard.reminderCount, "\(storage)")
        }
    }

    func testNoReminderMeansNoEntry() {
        XCTAssertTrue(entries([item("新鮮", in: chilled, expiresIn: 10), item("無日期", in: chilled)]).isEmpty)
    }

    // 25: dashboard filter preserved when navigating
    func testDashboardRowPassesCurrentStorageFilter() {
        let dashboard = DashboardView()
        var received: (ReminderKindFilter, StorageFilter)?
        dashboard.onSelectReminder = { received = ($0, $1) }
        let segmented = dashboard.allSubviews.compactMap { $0 as? UISegmentedControl }.first!
        segmented.selectedSegmentIndex = 2 // 冷凍
        segmented.sendActions(for: .valueChanged)
        let expiredRow = dashboard.allSubviews.first { $0.accessibilityIdentifier == "dashboard.expired" } as? UIControl
        expiredRow?.sendActions(for: .touchUpInside)
        XCTAssertEqual(received?.0, .expired)
        XCTAssertEqual(received?.1, .frozen)
    }

    func testReminderCenterOpensWithRequestedFilters() throws {
        let container = try FoodManager.SwiftDataFridgeStore.makeContainer(inMemory: true)
        let inventory = FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                                             compartments: { [unowned self] in self.fridge.allCompartments })
        var draft = FoodDraft(compartmentID: frozen)
        draft.name = "水餃"
        draft.expirationDate = Date().addingTimeInterval(-86_400 * 2)
        try inventory.add(draft)
        draft.compartmentID = chilled
        draft.name = "牛奶"
        try inventory.add(draft)
        let center = ReminderCenterViewController(inventory: inventory, compartments: { [unowned self] in self.fridge.allCompartments },
                                                  storageFilter: .frozen, kindFilter: .expired)
        center.loadViewIfNeeded()
        XCTAssertEqual(center.entries.map(\.item.name), ["水餃"])
        center.select(kind: .expired) // tapping the active tile again clears the kind filter
        XCTAssertEqual(center.kindFilter, .all)
        center.select(storage: .all)
        XCTAssertEqual(center.entries.count, 2)
        // Changes are reflected immediately.
        let milk = try XCTUnwrap(inventory.items.first { $0.name == "牛奶" })
        try inventory.markConsumed(milk.id)
        XCTAssertEqual(center.entries.map(\.item.name), ["水餃"])
    }
}

extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
