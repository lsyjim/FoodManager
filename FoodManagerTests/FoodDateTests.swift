import XCTest
@testable import FoodManager

/// 8–13: calendar-day storage duration, expiry countdown and reminders, incl. month/year/DST boundaries.
final class FoodDateTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private lazy var taipei = calendar("Asia/Taipei")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in cal: Calendar? = nil) -> Date {
        (cal ?? taipei).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func item(storedAt: Date, expiration: Date? = nil, remindAfter: Int? = nil) -> FoodItem {
        FoodItem(id: UUID(), name: "牛奶", categoryID: "dairy", quantity: 1, unit: "瓶", storedAt: storedAt,
                 expirationDate: expiration, storageReminderDays: remindAfter, fridgeID: UUID(), compartmentID: UUID(),
                 createdAt: storedAt, updatedAt: storedAt)
    }

    // 8: storage duration
    func testStorageDurationCountsCalendarDaysNotHours() {
        let dates = FoodDateCalculator(calendar: taipei)
        // Stored late at night, checked early next morning: 1 calendar day although only ~2 hours passed.
        XCTAssertEqual(dates.daysStored(since: date(2026, 10, 18, 23, 30), now: date(2026, 10, 19, 1, 30)), 1)
        XCTAssertEqual(dates.daysStored(since: date(2026, 10, 19, 0, 5), now: date(2026, 10, 19, 23, 55)), 0)
        XCTAssertEqual(dates.daysStored(since: date(2026, 10, 25), now: date(2026, 10, 19)), 0, "future dates clamp to 0")
    }

    func testStorageDurationAcrossMonthAndYearBoundaries() {
        let dates = FoodDateCalculator(calendar: taipei)
        XCTAssertEqual(dates.daysStored(since: date(2026, 1, 31), now: date(2026, 2, 1)), 1)
        XCTAssertEqual(dates.daysStored(since: date(2024, 2, 28), now: date(2024, 3, 1)), 2, "leap year")
        XCTAssertEqual(dates.daysStored(since: date(2025, 12, 31, 22), now: date(2026, 1, 1, 8)), 1)
        XCTAssertEqual(dates.daysStored(since: date(2025, 12, 20), now: date(2026, 1, 2)), 13)
    }

    func testStorageDurationAcrossDaylightSavingChange() {
        let newYork = calendar("America/New_York")
        let dates = FoodDateCalculator(calendar: newYork)
        // 2026-03-08 has 23 hours in New York; it is still exactly one calendar day.
        XCTAssertEqual(dates.daysStored(since: date(2026, 3, 8, 0, 30, in: newYork), now: date(2026, 3, 9, 0, 15, in: newYork)), 1)
    }

    func testStorageTexts() {
        XCTAssertEqual(FoodFormatting.storageText(daysStored: 0), "今天放入")
        XCTAssertEqual(FoodFormatting.storageText(daysStored: 3), "已存放 3 天")
        XCTAssertEqual(FoodFormatting.storageText(daysStored: 12), "已存放 12 天")
    }

    // 9–12: expiration
    func testNoExpirationDateMeansNoWarning() {
        let evaluator = FoodReminderEvaluator(calendar: taipei)
        let food = item(storedAt: date(2026, 1, 1))
        XCTAssertEqual(evaluator.expirationStatus(of: food, now: date(2026, 10, 19)), .none)
        XCTAssertNil(FoodFormatting.expirationText(.none))
        XCTAssertTrue(evaluator.reminders(for: food, now: date(2026, 10, 19)).isEmpty)
    }

    func testExpirationCountdownAndTexts() {
        let evaluator = FoodReminderEvaluator(calendar: taipei)
        let now = date(2026, 12, 30, 21)
        func status(_ expiry: Date) -> ExpirationStatus {
            evaluator.expirationStatus(of: item(storedAt: now, expiration: expiry), now: now)
        }
        XCTAssertEqual(status(date(2026, 12, 30, 1)), .expiringSoon(daysLeft: 0))
        XCTAssertEqual(status(date(2026, 12, 31, 8)), .expiringSoon(daysLeft: 1))
        XCTAssertEqual(status(date(2027, 1, 2)), .expiringSoon(daysLeft: 3), "inclusive 3-day window across the year end")
        XCTAssertEqual(status(date(2027, 1, 3)), .fresh(daysLeft: 4))
        XCTAssertEqual(status(date(2026, 12, 28)), .expired(daysAgo: 2))
        XCTAssertEqual(FoodFormatting.expirationText(.expiringSoon(daysLeft: 0)), "今天到期")
        XCTAssertEqual(FoodFormatting.expirationText(.expiringSoon(daysLeft: 1)), "明天到期")
        XCTAssertEqual(FoodFormatting.expirationText(.expiringSoon(daysLeft: 3)), "3 天後到期")
        XCTAssertEqual(FoodFormatting.expirationText(.fresh(daysLeft: 10)), "10 天後到期")
        XCTAssertEqual(FoodFormatting.expirationText(.expired(daysAgo: 2)), "已過期 2 天")
    }

    func testExpiredStartsTheDayAfterExpiration() {
        let evaluator = FoodReminderEvaluator(calendar: taipei)
        let expiry = date(2026, 2, 28, 9)
        let food = item(storedAt: date(2026, 2, 1), expiration: expiry)
        XCTAssertEqual(evaluator.expirationStatus(of: food, now: date(2026, 2, 28, 23, 59)), .expiringSoon(daysLeft: 0))
        XCTAssertEqual(evaluator.expirationStatus(of: food, now: date(2026, 3, 1, 0, 1)), .expired(daysAgo: 1))
    }

    func testExpiredAndExpiringSoonAreMutuallyExclusive() {
        let evaluator = FoodReminderEvaluator(calendar: taipei)
        let now = date(2026, 10, 19)
        for offset in -5...6 {
            let food = item(storedAt: now, expiration: taipei.date(byAdding: .day, value: offset, to: now))
            let reminders = evaluator.reminders(for: food, now: now)
            XCTAssertFalse(reminders.contains(.expired) && reminders.contains(.expiringSoon), "offset \(offset)")
        }
    }

    // 13: storage reminders
    func testStorageReminderTriggersOnTheNthCalendarDay() {
        let evaluator = FoodReminderEvaluator(calendar: taipei)
        let food = item(storedAt: date(2026, 1, 28, 20), remindAfter: 7)
        XCTAssertFalse(evaluator.isStorageReminderDue(food, now: date(2026, 2, 3, 23)))
        XCTAssertTrue(evaluator.isStorageReminderDue(food, now: date(2026, 2, 4, 0, 1)))
        XCTAssertFalse(evaluator.isStorageReminderDue(item(storedAt: date(2025, 1, 1)), now: date(2026, 2, 4)))
    }

    // 4: decimal quantities
    func testQuantityParsingAndFormatting() {
        XCTAssertEqual(FoodFormatting.parseQuantity("1.5"), Decimal(string: "1.5"))
        XCTAssertEqual(FoodFormatting.parseQuantity("1,5"), Decimal(string: "1.5"))
        XCTAssertEqual(FoodFormatting.parseQuantity(" 6 "), 6)
        XCTAssertNil(FoodFormatting.parseQuantity("abc"))
        XCTAssertNil(FoodFormatting.parseQuantity(""))
        XCTAssertEqual(FoodFormatting.quantityText(Decimal(string: "1.5")!, unit: "公升"), "1.5 公升")
        XCTAssertEqual(FoodFormatting.quantityText(6, unit: "顆"), "6 顆")
        XCTAssertEqual(FoodFormatting.number(Decimal(string: "0.25")!), "0.25")
    }
}
