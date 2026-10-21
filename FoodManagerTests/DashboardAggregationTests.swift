import XCTest
@testable import FoodManager

/// Classification is derived FoodItem → Compartment → StorageType; reminders are independent of each other.
/// (Phase 1.1 tests, updated for Phase 2: storage reminders now come from each item's `storageReminderDays`.)
final class DashboardAggregationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!

    private var fridge: Fridge!
    private var chilledShelf: Compartment { fridge.cabinetCompartments[0] }
    private var frozenShelf: Compartment { fridge.cabinetCompartments[1] }
    private var doorShelf: Compartment { fridge.doorCompartments[0] }

    override func setUp() {
        super.setUp()
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[1].storageType = .frozen
    }

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    private func item(in compartment: UUID, storedDaysAgo: Int = 0, expiresIn: Int? = nil, remindAfter: Int? = nil) -> FoodItem {
        FoodItem(id: UUID(), name: "x", categoryID: "other", quantity: 1, unit: "個", storedAt: day(-storedDaysAgo),
                 expirationDate: expiresIn.map(day), storageReminderDays: remindAfter, fridgeID: fridge.id,
                 compartmentID: compartment, createdAt: now, updatedAt: now)
    }

    private var aggregator: DashboardAggregator {
        DashboardAggregator(evaluator: FoodReminderEvaluator(policy: .standard, calendar: calendar))
    }

    private func summary(_ items: [FoodItem], _ filter: StorageFilter) -> DashboardSummary {
        aggregator.summary(items: items, compartments: fridge.allCompartments, filter: filter, now: now)
    }

    // 14–17: refrigerated / frozen / all / unspecified.
    func testFiltersByCompartmentStorageType() {
        let items = [item(in: chilledShelf.id), item(in: chilledShelf.id), item(in: frozenShelf.id),
                     item(in: doorShelf.id), item(in: UUID())]
        XCTAssertEqual(summary(items, .all).itemCount, 5, "unspecified and missing locations still count in 全部")
        XCTAssertEqual(summary(items, .refrigerated).itemCount, 2)
        XCTAssertEqual(summary(items, .frozen).itemCount, 1)
    }

    func testConsumedItemsAreExcluded() {
        var eaten = item(in: chilledShelf.id)
        eaten.consumedAt = now
        XCTAssertEqual(summary([eaten, item(in: chilledShelf.id)], .all).itemCount, 1)
    }

    func testMovingFoodChangesClassificationWithoutTouchingFoodItem() {
        var food = item(in: chilledShelf.id)
        XCTAssertEqual(summary([food], .frozen).itemCount, 0)
        food.compartmentID = frozenShelf.id
        XCTAssertEqual(summary([food], .frozen).itemCount, 1)
        XCTAssertEqual(summary([food], .refrigerated).itemCount, 0)
    }

    func testReclassifyingCompartmentReclassifiesItsFood() {
        let food = item(in: chilledShelf.id)
        fridge.cabinetCompartments[0].storageType = .frozen
        XCTAssertEqual(summary([food], .frozen).itemCount, 1)
    }

    func testExpiryRemindersUseOnlyExpirationDate() {
        let items = [item(in: chilledShelf.id, expiresIn: -1),   // expired
                     item(in: chilledShelf.id, expiresIn: 0),    // today: expiring soon, not expired
                     item(in: chilledShelf.id, expiresIn: 3),    // edge of window
                     item(in: chilledShelf.id, expiresIn: 4),    // outside window
                     item(in: chilledShelf.id, expiresIn: nil)]  // no date: no expiry warning
        let result = summary(items, .refrigerated)
        XCTAssertEqual(result.expiredCount, 1)
        XCTAssertEqual(result.expiringSoonCount, 2, "expired and expiring soon never double-count")
    }

    func testStorageReminderIsIndependentOfExpiry() {
        let evaluator = FoodReminderEvaluator(policy: .standard, calendar: calendar)
        XCTAssertEqual(evaluator.reminders(for: item(in: chilledShelf.id, storedDaysAgo: 7, remindAfter: 7), now: now),
                       [.storedTooLong])
        XCTAssertEqual(evaluator.reminders(for: item(in: chilledShelf.id, storedDaysAgo: 10, expiresIn: -2, remindAfter: 7), now: now),
                       [.storedTooLong, .expired])
        XCTAssertEqual(evaluator.reminders(for: item(in: chilledShelf.id, storedDaysAgo: 400), now: now), [],
                       "no reminder days set → never a storage reminder")
    }

    func testStorageReminderCountsPerFilter() {
        let items = [item(in: chilledShelf.id, storedDaysAgo: 30, remindAfter: 7),
                     item(in: frozenShelf.id, storedDaysAgo: 30, remindAfter: 90),
                     item(in: doorShelf.id, storedDaysAgo: 5, remindAfter: 5)]
        XCTAssertEqual(summary(items, .refrigerated).reminderCount, 1)
        XCTAssertEqual(summary(items, .frozen).reminderCount, 0)
        XCTAssertEqual(summary(items, .all).reminderCount, 2)
    }

    func testFrozenExpiryIsNotExtendedAutomatically() {
        XCTAssertEqual(summary([item(in: frozenShelf.id, expiresIn: -1)], .frozen).expiredCount, 1)
    }

    func testPlaceholderProviderNeverInventsNumbers() {
        for filter in StorageFilter.allCases {
            XCTAssertEqual(PlaceholderDashboardProvider().summary(for: filter), .placeholder)
        }
    }
}
