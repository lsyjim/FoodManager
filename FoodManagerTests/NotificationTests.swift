import XCTest
@testable import FoodManager

/// Test double for the system notification center; no real authorization is needed.
final class FakeNotificationClient: NotificationClient {
    var status: NotificationAuthorization = .authorized
    var grantOnRequest = true
    var pending: [String: PlannedNotification] = [:]
    var delivered: [String] = []
    var addCount = 0

    func authorizationStatus() async -> NotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        status = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ notification: PlannedNotification) async throws {
        addCount += 1
        pending[notification.identifier] = notification // same identifier replaces, like UNUserNotificationCenter
    }
    func removePending(identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func removeDelivered(identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
}

final class InMemoryPreferencesStore: NotificationPreferencesStore {
    var value = NotificationPreferences()
    func load() -> NotificationPreferences { value }
    func save(_ preferences: NotificationPreferences) { value = preferences }
}

/// 16–24: scheduling rules, cancellation, permission states, DST and deep links.
@MainActor
final class NotificationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()
    private var fridge: Fridge!
    private var inventory: FoodInventoryService!
    private var client: FakeNotificationClient!
    private var preferences: InMemoryPreferencesStore!
    private var now: Date!
    private var coordinator: NotificationCoordinator!

    override func setUpWithError() throws {
        fridge = FridgeFactory.makeDefault()
        now = date(2026, 10, 22, 10)
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        inventory = FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                                         compartments: { [unowned self] in self.fridge.allCompartments },
                                         now: { [unowned self] in self.now })
        client = FakeNotificationClient()
        preferences = InMemoryPreferencesStore()
        coordinator = NotificationCoordinator(client: client, preferencesStore: preferences,
                                              planner: NotificationPlanner(calendar: calendar),
                                              now: { [unowned self] in self.now },
                                              snapshot: { [unowned self] in (self.inventory.items, self.fridge.allCompartments) })
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in cal: Calendar? = nil) -> Date {
        (cal ?? calendar).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @discardableResult
    private func add(_ name: String, expiration: Date? = nil, remindAfter: Int? = nil, storedAt: Date? = nil) throws -> FoodItem {
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id, now: storedAt ?? now)
        draft.name = name
        draft.expirationDate = expiration
        draft.storageReminderDays = remindAfter
        return try inventory.add(draft)
    }

    private func fireDate(_ item: FoodItem, _ kind: NotificationKind) -> DateComponents? {
        client.pending[PlannedNotification.identifier(foodID: item.id, kind: kind)]?.fireDate
    }

    // 16 & 18
    func testExpirationNotificationOneDayBeforeAtNine() async throws {
        let milk = try add("牛奶", expiration: date(2026, 10, 30, 18))
        let noDate = try add("醬油")
        await coordinator.reschedule()
        XCTAssertEqual(fireDate(milk, .expiration), DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 0))
        XCTAssertEqual(client.pending[PlannedNotification.identifier(foodID: milk.id, kind: .expiration)]?.body,
                       "「牛奶」（櫃內 · 上層）明天到期")
        XCTAssertNil(fireDate(noDate, .expiration), "no expiration date → no expiration notification")
        XCTAssertEqual(client.pending.count, 1)
    }

    func testPassedLeadTimeFallsToNextReminderTimeButNeverIntoThePast() async throws {
        // 10:00 today, expires tomorrow: today's 09:00 has passed → tomorrow 09:00 ("今天到期").
        let tomorrow = try add("豆腐", expiration: date(2026, 10, 23))
        // Expires today: next 09:00 is tomorrow, after expiry → nothing.
        let today = try add("壽司", expiration: date(2026, 10, 22))
        let expired = try add("優格", expiration: date(2026, 10, 20))
        await coordinator.reschedule()
        XCTAssertEqual(fireDate(tomorrow, .expiration), DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 0))
        XCTAssertEqual(client.pending[PlannedNotification.identifier(foodID: tomorrow.id, kind: .expiration)]?.body,
                       "「豆腐」（櫃內 · 上層）今天到期")
        XCTAssertNil(fireDate(today, .expiration))
        XCTAssertNil(fireDate(expired, .expiration), "already expired food is shown in the reminder center instead")
    }

    // 17
    func testStorageNotificationIndependentOfExpiration() async throws {
        let rice = try add("白飯", remindAfter: 3)
        let overdue = try add("剩菜", remindAfter: 2, storedAt: date(2026, 10, 10))
        await coordinator.reschedule()
        XCTAssertEqual(fireDate(rice, .storage), DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 0))
        XCTAssertNil(fireDate(rice, .expiration))
        XCTAssertNil(fireDate(overdue, .storage), "already past the threshold → no past-dated trigger")
    }

    func testPreferencesDisableTypesIndependentlyAndChangeTime() async throws {
        let item = try add("雞蛋", expiration: date(2026, 11, 5), remindAfter: 5)
        preferences.value.storageRemindersEnabled = false
        preferences.value.reminderHour = 20
        preferences.value.reminderMinute = 30
        preferences.value.expirationLeadDays = 2
        await coordinator.reschedule()
        XCTAssertNil(fireDate(item, .storage))
        XCTAssertEqual(fireDate(item, .expiration), DateComponents(year: 2026, month: 11, day: 3, hour: 20, minute: 30))
        preferences.value.expirationRemindersEnabled = false
        await coordinator.reschedule()
        XCTAssertTrue(client.pending.isEmpty, "disabled types are cancelled")
    }

    // 19, 20, 21
    func testConsumeDeleteAndEditUpdatePendingNotifications() async throws {
        let milk = try add("牛奶", expiration: date(2026, 11, 1))
        let fish = try add("魚", expiration: date(2026, 11, 2), remindAfter: 4)
        await coordinator.reschedule()
        XCTAssertEqual(client.pending.count, 3)

        var edit = FoodDraft(item: milk)
        edit.expirationDate = date(2026, 11, 10)
        try inventory.update(milk.id, with: edit)
        await coordinator.reschedule()
        XCTAssertEqual(fireDate(milk, .expiration)?.day, 9, "edit replaced the old trigger")
        XCTAssertEqual(client.pending.count, 3, "no duplicates")

        client.delivered = [PlannedNotification.identifier(foodID: milk.id, kind: .expiration)]
        try inventory.markConsumed(milk.id)
        await coordinator.reschedule()
        XCTAssertNil(fireDate(milk, .expiration))
        XCTAssertTrue(client.delivered.isEmpty, "delivered notifications for eaten food are cleared")

        try inventory.delete(fish.id)
        await coordinator.reschedule()
        XCTAssertTrue(client.pending.isEmpty)
    }

    func testMovingFoodUpdatesNotificationText() async throws {
        let milk = try add("牛奶", expiration: date(2026, 11, 1))
        try inventory.move(milk.id, to: fridge.doorCompartments[0].id)
        await coordinator.reschedule()
        XCTAssertEqual(client.pending[PlannedNotification.identifier(foodID: milk.id, kind: .expiration)]?.body,
                       "「牛奶」（門內 · 門架 1）明天到期")
    }

    // 22
    func testPermissionDeniedSchedulesNothingAndClearsPending() async throws {
        try add("牛奶", expiration: date(2026, 11, 1))
        await coordinator.reschedule()
        XCTAssertFalse(client.pending.isEmpty)
        client.status = .denied
        let scheduled = await coordinator.reschedule()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertFalse(inventory.items.isEmpty, "food management keeps working without permission")
    }

    func testRequestAuthorizationOutcomes() async throws {
        try add("牛奶", expiration: date(2026, 11, 1))
        client.status = .notDetermined
        client.grantOnRequest = false
        let denied = await coordinator.requestAuthorization()
        XCTAssertEqual(denied, .denied)
        XCTAssertTrue(client.pending.isEmpty)
        client.status = .notDetermined
        client.grantOnRequest = true
        let granted = await coordinator.requestAuthorization()
        XCTAssertEqual(granted, .authorized)
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertTrue(NotificationAuthorization.provisional.canSchedule)
        XCTAssertFalse(NotificationAuthorization.notDetermined.canSchedule)
    }

    func testPendingCountIsBounded() async throws {
        for i in 0..<80 { try add("食材\(i)", expiration: date(2026, 11, 1 + i % 25)) }
        let scheduled = await coordinator.reschedule()
        XCTAssertEqual(scheduled.count, NotificationPlanner.maxPending)
        XCTAssertEqual(client.pending.count, NotificationPlanner.maxPending)
        let dates = scheduled.compactMap { calendar.date(from: $0.fireDate) }
        XCTAssertEqual(dates, dates.sorted(), "soonest first")
    }

    // 23
    func testDaylightSavingTransitionKeepsLocalTime() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let planner = NotificationPlanner(calendar: newYork)
        let now = date(2026, 3, 1, 12, in: newYork)
        let item = FoodItem(id: UUID(), name: "牛奶", categoryID: "dairy", quantity: 1, unit: "瓶", storedAt: now,
                            expirationDate: date(2026, 3, 9, 12, in: newYork), storageReminderDays: 7,
                            fridgeID: fridge.id, compartmentID: UUID(), createdAt: now, updatedAt: now)
        let plan = planner.plan(items: [item], compartments: [], preferences: NotificationPreferences(), now: now)
        // DST starts 2026-03-08 in New York; both triggers stay at 09:00 local on the right calendar day.
        XCTAssertEqual(plan.first { $0.kind == .expiration }?.fireDate, DateComponents(year: 2026, month: 3, day: 8, hour: 9, minute: 0))
        XCTAssertEqual(plan.first { $0.kind == .storage }?.fireDate, DateComponents(year: 2026, month: 3, day: 8, hour: 9, minute: 0))
        XCTAssertEqual(plan.first?.body, "「牛奶」明天到期", "unknown compartment omits the location")
    }

    // 24
    func testDeepLinkPayloadAndRouting() throws {
        let milk = try add("牛奶", expiration: date(2026, 11, 1))
        let planned = NotificationPlanner(calendar: calendar).plan(items: [milk], compartments: fridge.allCompartments,
                                                                   preferences: NotificationPreferences(), now: now)[0]
        let userInfo: [AnyHashable: Any] = NotificationPayload.userInfo(for: planned)
        XCTAssertEqual(NotificationPayload.foodID(from: userInfo), milk.id)
        XCTAssertEqual(PlannedNotification.foodID(fromIdentifier: planned.identifier), milk.id)
        XCTAssertNil(NotificationPayload.foodID(from: ["foodID": "garbage"]))
        XCTAssertFalse(AppNotificationRouter().handle(userInfo: ["other": 1]))

        XCTAssertEqual(FoodRoute.resolve(foodID: milk.id, inventory: inventory), .editor(milk.id))
        try inventory.markConsumed(milk.id)
        XCTAssertEqual(FoodRoute.resolve(foodID: milk.id, inventory: inventory), .missing, "consumed → safe fallback")
        XCTAssertEqual(FoodRoute.resolve(foodID: UUID(), inventory: inventory), .missing, "deleted → safe fallback")
    }

    func testPreferencesPersist() {
        let suite = "NotificationTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UserDefaultsNotificationPreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(store.load(), NotificationPreferences())
        var custom = NotificationPreferences()
        custom.reminderHour = 7
        custom.storageRemindersEnabled = false
        store.save(custom)
        XCTAssertEqual(UserDefaultsNotificationPreferencesStore(defaults: UserDefaults(suiteName: suite)!).load(), custom)
    }
}

/// Regression: bursts of `scheduleUpdate()` must never run reschedules concurrently.
@MainActor
final class NotificationSerializationTests: XCTestCase {
    final class OverlapClient: NotificationClient {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var runs = 0

        private func enter() { lock.lock(); active += 1; maxActive = max(maxActive, active); runs += 1; lock.unlock() }
        private func leave() { lock.lock(); active -= 1; lock.unlock() }

        func authorizationStatus() async -> NotificationAuthorization { .authorized }
        func requestAuthorization() async throws -> Bool { true }
        func pendingIdentifiers() async -> [String] {
            enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            leave()
            return []
        }
        func deliveredIdentifiers() async -> [String] { [] }
        func add(_ notification: PlannedNotification) async throws {}
        func removePending(identifiers: [String]) {}
        func removeDelivered(identifiers: [String]) {}
    }

    func testBurstOfUpdatesNeverOverlapsAndCollapses() async {
        let client = OverlapClient()
        let coordinator = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(),
                                                  snapshot: { ([], []) })
        for _ in 0..<20 { coordinator.scheduleUpdate() }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(client.maxActive, 1, "reschedules are serialized")
        XCTAssertLessThan(client.runs, 20, "superseded updates are skipped")
        XCTAssertGreaterThanOrEqual(client.runs, 1)
    }
}
