import SwiftData
import UIKit
import XCTest
@testable import FoodManager

final class CountingReloader: WidgetReloading {
    private(set) var count = 0
    func reloadAll() { count += 1 }
}

/// Phase 3.2: widget snapshot, publishing, deep links, routing and quick add.
final class WidgetIntegrationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!
    private var fridge: Fridge!
    private var directory: URL!

    override func setUpWithError() throws {
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[1].storageType = .frozen
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var chilled: UUID { fridge.cabinetCompartments[0].id }
    private var frozen: UUID { fridge.cabinetCompartments[1].id }
    private var door: UUID { fridge.doorCompartments[0].id }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    private func item(_ name: String, in compartment: UUID, expiresIn: Int? = nil, storedDaysAgo: Int = 0,
                      remindAfter: Int? = nil, consumed: Bool = false) -> FoodItem {
        FoodItem(id: UUID(), name: name, categoryID: "dairy", quantity: 1, unit: "瓶", storedAt: day(-storedDaysAgo),
                 expirationDate: expiresIn.map(day), storageReminderDays: remindAfter, fridgeID: fridge.id,
                 compartmentID: compartment, createdAt: now, updatedAt: now, consumedAt: consumed ? now : nil)
    }

    private var evaluator: FoodReminderEvaluator { FoodReminderEvaluator(calendar: calendar) }

    // MARK: Snapshot content

    func testSnapshotCountsMatchDashboardAndExcludeIrrelevantData() {
        let items = [item("牛奶", in: chilled, expiresIn: 1), item("菠菜", in: chilled, expiresIn: -1),
                     item("水餃", in: frozen, storedDaysAgo: 30, remindAfter: 21), item("醬油", in: door, expiresIn: 0),
                     item("起司", in: chilled), item("吃掉了", in: chilled, expiresIn: -5, consumed: true)]
        let snapshot = WidgetSnapshotBuilder.build(fridge: fridge, items: items, now: now, evaluator: evaluator)
        XCTAssertEqual(snapshot.activeFoodCount, 5)
        XCTAssertEqual(snapshot.urgentFoodItems.map(\.name).sorted(), ["水餃", "牛奶", "菠菜", "醬油"],
                       "only foods that can need attention; consumed and date-less foods are not shared")
        XCTAssertEqual(snapshot.refrigeratedReminderCount, 2)
        XCTAssertEqual(snapshot.frozenReminderCount, 1)
        XCTAssertEqual(snapshot.unspecifiedReminderCount, 1)
        for filter in StorageFilter.allCases where filter != .all {
            let dashboard = DashboardAggregator(evaluator: evaluator)
                .summary(items: items, compartments: fridge.allCompartments, filter: filter, now: now)
            let summary = snapshot.summary(at: now, evaluator: evaluator)
            XCTAssertEqual(summary.entries.filter { filter.includes($0.item.storage) && $0.kinds.contains(.expired) }.count,
                           dashboard.expiredCount, "\(filter)")
        }
        XCTAssertEqual(snapshot.expiredCount, 1)
        XCTAssertEqual(snapshot.expiringSoonCount, 2)
        XCTAssertEqual(snapshot.storageReminderCount, 1)
        XCTAssertEqual(snapshot.urgentFoodItems.first { $0.name == "牛奶" }?.locationName, "櫃內 · 上層")
        XCTAssertEqual(snapshot.urgentFoodItems.first { $0.name == "牛奶" }?.categoryAssetName, "category_dairy")
    }

    func testSummaryIsOneEntryPerFoodInUrgencyOrderAndRollsOverByDay() {
        let items = [item("明天", in: chilled, expiresIn: 1), item("過期", in: chilled, expiresIn: -2, storedDaysAgo: 9, remindAfter: 3),
                     item("下週", in: frozen, expiresIn: 6)]
        let snapshot = WidgetSnapshotBuilder.build(fridge: fridge, items: items, now: now, evaluator: evaluator)
        let today = snapshot.summary(at: now, evaluator: evaluator)
        XCTAssertEqual(today.entries.map(\.item.name), ["過期", "明天"])
        XCTAssertEqual(today.attentionCount, 2, "expired + storage reminder counts the food once")
        XCTAssertEqual(today.entries[0].primaryStatus, "已過期 2 天")
        // Three days later (no app launch needed): 明天 has expired, 下週 is expiring soon.
        let later = snapshot.summary(at: day(3), evaluator: evaluator)
        XCTAssertEqual(later.expiredCount, 2)
        XCTAssertEqual(later.frozenCount, 1)
        XCTAssertEqual(later.entries.first { $0.item.name == "下週" }?.primaryStatus, "3 天後到期")
    }

    func testSnapshotIsBounded() {
        let many = (0..<(WidgetSnapshot.maxItems + 20)).map { item("i\($0)", in: chilled, expiresIn: $0 % 40) }
        let snapshot = WidgetSnapshotBuilder.build(fridge: fridge, items: many, now: now, evaluator: evaluator)
        XCTAssertEqual(snapshot.urgentFoodItems.count, WidgetSnapshot.maxItems)
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertLessThanOrEqual(snapshot.urgentFoodItems.compactMap(\.expirationDate).max()!, day(39))
    }

    // MARK: File + publisher

    func testSnapshotFileRoundTripAndMalformedData() throws {
        let file = WidgetSnapshotFile(url: directory.appendingPathComponent("s.json"))
        XCTAssertNil(file.read(), "missing file → nil")
        let snapshot = WidgetSnapshotBuilder.build(fridge: fridge, items: [item("牛奶", in: chilled, expiresIn: 1)], now: now)
        let bundle = WidgetSnapshotBundle(bundleVersion: WidgetSnapshotBundle.currentVersion, generatedAt: now,
                                          selectedFridgeID: fridge.id, fridges: [snapshot])
        try file.write(WidgetSnapshotFile.encode(bundle))
        XCTAssertEqual(file.read(), bundle)
        try file.write(Data("{garbage".utf8))
        XCTAssertNil(file.read(), "malformed → nil, never wrong numbers")
        var future = bundle
        future.bundleVersion = 99
        try file.write(WidgetSnapshotFile.encode(future))
        XCTAssertNil(file.read(), "unknown version → nil")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try file.write(encoder.encode(snapshot))
        XCTAssertNil(file.read(), "an old single-fridge (v1) file is ignored until the app rewrites it")
    }

    func testPublisherWritesAndReloadsOnlyOnChanges() throws {
        let file = WidgetSnapshotFile(url: directory.appendingPathComponent("s.json"))
        let reloader = CountingReloader()
        let publisher = WidgetSnapshotPublisher(file: file, reloader: reloader, calendar: calendar)
        let milk = item("牛奶", in: chilled, expiresIn: 1)

        publisher.publish(fridges: [fridge], items: [milk], selectedFridgeID: fridge.id, now: now)
        publisher.waitUntilIdle()
        drainMain()
        XCTAssertEqual(file.read()?.fridges.first?.urgentFoodItems.map(\.id), [milk.id])
        XCTAssertEqual(reloader.count, 1)

        publisher.publish(fridges: [fridge], items: [milk], selectedFridgeID: fridge.id, now: now.addingTimeInterval(60))
        publisher.waitUntilIdle()
        drainMain()
        XCTAssertEqual(reloader.count, 1, "unchanged content → no extra reload")

        publisher.publish(fridges: [fridge], items: [], selectedFridgeID: fridge.id, now: now.addingTimeInterval(120))
        publisher.waitUntilIdle()
        drainMain()
        XCTAssertEqual(reloader.count, 2)
        XCTAssertEqual(file.read()?.fridges.first?.urgentFoodItems, [])

        publisher.publish(fridges: [fridge], items: [], selectedFridgeID: fridge.id, now: day(1))
        publisher.waitUntilIdle()
        drainMain()
        XCTAssertEqual(reloader.count, 3, "a new day refreshes a stale snapshot")
    }

    func testPublisherWithoutAppGroupDoesNothing() {
        let reloader = CountingReloader()
        let publisher = WidgetSnapshotPublisher(file: nil, reloader: reloader)
        publisher.publish(fridges: [fridge], items: [item("牛奶", in: chilled)], selectedFridgeID: fridge.id, now: now)
        publisher.waitUntilIdle()
        drainMain()
        XCTAssertEqual(reloader.count, 0)
    }

    @MainActor
    func testTemporaryStorageNeverPublishesToWidgets() throws {
        let file = WidgetSnapshotFile(url: directory.appendingPathComponent("s.json"))
        let marker = Data("existing".utf8)
        try file.write(marker)
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        let home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient())
        home.loadViewIfNeeded()
        XCTAssertEqual(session.mode, .inMemoryForTesting)
        XCTAssertEqual(try Data(contentsOf: file.url), marker)
        if let shared = WidgetSnapshotFile.shared, let before = try? Data(contentsOf: shared.url) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(try? Data(contentsOf: shared.url), before, "the real widget snapshot is untouched")
        }
    }

    func testAppGroupContainerIsAvailableInTheHostApp() {
        XCTAssertNotNil(AppGroup.containerURL, "App Group entitlement is signed into the app")
    }

    private func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    // MARK: Deep links

    func testDeepLinksRoundTrip() {
        let id = UUID(), fridgeID = UUID()
        let links: [AppDeepLink] = [
            AppDeepLink(.home), AppDeepLink(.quickAdd(compartmentID: nil)), AppDeepLink(.quickAdd(compartmentID: id), refrigeratorID: fridgeID),
            AppDeepLink(.reminders(storage: .frozen, kind: .expired)), AppDeepLink(.reminders(storage: .all, kind: .storedTooLong)),
            AppDeepLink(.food(id)),
        ]
        for link in links { XCTAssertEqual(AppDeepLink(url: link.url), link, link.url.absoluteString) }
        XCTAssertEqual(AppDeepLink(url: URL(string: "foodmanager://reminders")!)?.destination, .reminders(storage: .all, kind: .all))
    }

    func testInvalidDeepLinksAreRejected() {
        for raw in ["foodmanager://food", "foodmanager://food?id=nope", "foodmanager://add?compartment=123",
                    "foodmanager://reminders?storage=fridge", "foodmanager://reminders?kind=x", "foodmanager://unknown",
                    "foodmanager://home?fridge=bad", "https://example.com/add", "foodmanager://food?id=\(UUID())&id=\(UUID())"] {
            XCTAssertNil(AppDeepLink(url: URL(string: raw)!), raw)
        }
    }

    func testRouterQueuesUntilHomeIsReadyAndIgnoresForeignSchemes() {
        let router = AppNotificationRouter()
        XCTAssertFalse(router.handle(url: URL(string: "https://example.com")!))
        XCTAssertTrue(router.handle(url: URL(string: "foodmanager://nope")!))
        XCTAssertEqual(router.pending, .invalidLink)
        XCTAssertTrue(router.handle(url: AppDeepLink(.quickAdd(compartmentID: nil)).url))
        XCTAssertEqual(router.pending, .link(AppDeepLink(.quickAdd(compartmentID: nil))), "latest request replaces the older one")
    }
}

/// Routing on a real home screen (in-memory storage).
@MainActor
final class HomeRoutingTests: XCTestCase {
    private var window: UIWindow!
    private var home: FridgeHomeViewController!
    private var session: AppSession!

    override func setUpWithError() throws {
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        self.session = session
        home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient(),
                                        widgetPublisher: WidgetSnapshotPublisher(file: nil, reloader: CountingReloader()))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: home)
        window.makeKeyAndVisible()
        home.loadViewIfNeeded()
    }

    override func tearDown() {
        window.rootViewController?.dismiss(animated: false)
        window = nil
        super.tearDown()
    }

    private var fridge: Fridge { session.loadResult.fridge }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    private var presentedEditor: FoodEditorViewController? {
        (home.navigationController?.presentedViewController as? UINavigationController)?.viewControllers.first as? FoodEditorViewController
    }

    func testQuickAddOpensAddFormWithLastUsedCompartmentAndCleanDefaults() throws {
        let inventory = FoodInventoryService(store: session.foodStore, fridgeID: fridge.id, compartments: { [fridge] in fridge.allCompartments })
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[2].id)
        draft.name = "上次的"
        draft.expirationDate = Date()
        draft.storageReminderDays = 9
        draft.quantity = 4
        try inventory.add(draft)
        // A fresh home (as after launch) sees the stored food.
        home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient(),
                                        widgetPublisher: WidgetSnapshotPublisher(file: nil, reloader: CountingReloader()))
        window.rootViewController = UINavigationController(rootViewController: home)
        home.loadViewIfNeeded()
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: nil))))
        settle()
        let editor = try XCTUnwrap(presentedEditor)
        XCTAssertTrue(editor.isAddMode)
        XCTAssertEqual(editor.draft.compartmentID, fridge.cabinetCompartments[2].id, "last valid compartment preselected")
        XCTAssertEqual(editor.draft.quantity, 1)
        XCTAssertNil(editor.draft.expirationDate)
        XCTAssertNil(editor.draft.storageReminderDays)
        XCTAssertTrue(Calendar.current.isDateInToday(editor.draft.storedAt))

        // Repeated quick-add taps keep the same form (no stacking).
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: nil))))
        settle()
        XCTAssertTrue(presentedEditor === editor)
    }

    func testQuickAddValidatesRequestedCompartment() throws {
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: fridge.doorCompartments[1].id))))
        settle()
        XCTAssertEqual(try XCTUnwrap(presentedEditor).draft.compartmentID, fridge.doorCompartments[1].id)
        presentedEditor?.dismiss(animated: false)
        settle()
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: UUID()))))
        settle()
        XCTAssertNil(try XCTUnwrap(presentedEditor).draft.compartmentID, "unknown compartment is never assumed")
    }

    func testReminderLinkPushesSingleFilteredReminderCenter() throws {
        home.handle(.link(AppDeepLink(.reminders(storage: .frozen, kind: .expired))))
        settle()
        home.handle(.link(AppDeepLink(.reminders(storage: .refrigerated, kind: .all))))
        settle()
        let stack = try XCTUnwrap(home.navigationController?.viewControllers)
        XCTAssertEqual(stack.count, 2, "repeated links don't duplicate the stack")
        let center = try XCTUnwrap(stack.last as? ReminderCenterViewController)
        XCTAssertEqual(center.storageFilter, .refrigerated)
        XCTAssertEqual(center.kindFilter, .all)
    }

    func testInvalidLinksLandOnHome() throws {
        home.handle(.link(AppDeepLink(.reminders(storage: .all, kind: .all))))
        settle()
        home.handle(.link(AppDeepLink(.home, refrigeratorID: UUID()))) // unknown fridge
        settle()
        XCTAssertEqual(home.navigationController?.viewControllers.count, 1)
        home.handle(.invalidLink)
        // Checked before the run loop turns: the message fades out on its own shortly after.
        XCTAssertTrue(home.view.allSubviews.contains { ($0 as? UILabel)?.text == "無法開啟這個連結，已回到冰箱" },
                      "the user is told why nothing opened")
        settle()
        XCTAssertEqual(home.navigationController?.viewControllers.count, 1)
        home.handle(.link(AppDeepLink(.food(UUID())))) // missing food → safe message, no editor
        settle()
        XCTAssertNil(presentedEditor)
        XCTAssertTrue(home.navigationController?.presentedViewController is UIAlertController)
    }

    func testOpenEditorIsNeverReplacedByAnotherLink() throws {
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: nil))))
        settle()
        let editor = try XCTUnwrap(presentedEditor)
        editor.draft.name = "還沒存"
        home.handle(.link(AppDeepLink(.reminders(storage: .all, kind: .all))))
        settle()
        XCTAssertTrue(presentedEditor === editor, "unsaved input is kept")
        XCTAssertEqual(editor.draft.name, "還沒存")
        XCTAssertEqual(home.navigationController?.viewControllers.count, 1)
    }
}
