import SwiftData
import UIKit
import XCTest
@testable import FoodManager

/// FridgeStore wrapper whose writes can be made to fail.
final class FailingFridgeStore: FridgeStore {
    struct Failure: Error {}
    let base: FridgeStore
    var failWrites = false
    init(base: FridgeStore) { self.base = base }

    func load() throws -> FridgeLoadResult { try base.load() }
    func saveLayout(_ fridge: Fridge) throws { if failWrites { throw Failure() }; try base.saveLayout(fridge) }
    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws { if failWrites { throw Failure() }; try base.saveDoorState(state, fridgeID: fridgeID) }
    func loadAll() throws -> [FridgeLoadResult] { try base.loadAll() }
    func create(_ fridge: Fridge) throws { if failWrites { throw Failure() }; try base.create(fridge) }
    func rename(fridgeID: UUID, to name: String) throws { if failWrites { throw Failure() }; try base.rename(fridgeID: fridgeID, to: name) }
    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws {
        if failWrites { throw Failure() }
        try base.deleteFridge(fridgeID, moveHistoryTo: historyDestination)
    }
}

/// Phase 4.1: up to two free fridges, isolation, switching, deletion, notifications, widgets, migration.
final class MultiFridgeTests: XCTestCase {
    private var container: ModelContainer!
    private var fridgeStore: FailingFridgeStore!
    private var foodStore: SwiftDataFoodStore!
    private var selection: InMemoryFridgeSelectionStore!
    private var directory: FridgeDirectory!

    override func setUpWithError() throws {
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        fridgeStore = FailingFridgeStore(base: SwiftDataFridgeStore(container: container))
        foodStore = SwiftDataFoodStore(container: container)
        selection = InMemoryFridgeSelectionStore()
        directory = try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore, selection: selection)
    }

    private var first: Fridge { directory.fridges[0] }

    private func inventory(for fridge: Fridge) -> FoodInventoryService {
        FoodInventoryService(store: foodStore, fridgeID: fridge.id, compartments: { [unowned self] in
            self.directory.fridge(id: fridge.id)?.allCompartments ?? []
        })
    }

    @discardableResult
    private func addFood(_ name: String, to fridge: Fridge, compartment index: Int = 0, expiresIn days: Int? = nil) throws -> FoodItem {
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[index].id)
        draft.name = name
        draft.expirationDate = days.map { Date().addingTimeInterval(Double($0) * 86_400) }
        return try inventory(for: fridge).add(draft)
    }

    // 1
    func testFirstLaunchCreatesOneDefaultFridge() {
        XCTAssertEqual(directory.fridges.count, 1)
        XCTAssertEqual(first.name, FridgePolicy.defaultName)
        XCTAssertEqual(first.templateID, FridgeTemplate.standardSingleDoor.id)
        XCTAssertEqual(directory.selectedID, first.id)
        XCTAssertTrue(directory.canAddFridge)
        XCTAssertEqual(try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore, selection: selection).fridges.count, 1,
                       "no duplicate default fridge on the next launch")
    }

    // 2, 3
    func testSecondFridgeIsAllowedThirdIsRejected() throws {
        let second = try directory.create(name: "  儲藏室冰箱 ")
        XCTAssertEqual(second.name, "儲藏室冰箱")
        XCTAssertEqual(second.cabinetCompartments.count, first.cabinetCompartments.count, "standard default layout")
        XCTAssertEqual(directory.fridges.map(\.id), [first.id, second.id])
        XCTAssertFalse(directory.canAddFridge)
        XCTAssertThrowsError(try directory.create(name: "第三台")) {
            XCTAssertEqual($0 as? FridgeDirectoryError, .limitReached)
            XCTAssertEqual(($0 as? FridgeDirectoryError)?.message, "目前最多可建立 2 台冰箱。")
        }
        XCTAssertEqual(try fridgeStore.loadAll().count, 2)
        XCTAssertThrowsError(try directory.create(name: "   "))
    }

    func testCreateFailureChangesNothing() throws {
        fridgeStore.failWrites = true
        XCTAssertThrowsError(try directory.create(name: "第二台"))
        XCTAssertEqual(directory.fridges.count, 1)
        XCTAssertEqual(directory.selectedID, first.id, "no switch after a failed save")
    }

    // 4
    func testRenamePersistsAndValidates() throws {
        try directory.rename(first.id, to: "廚房冰箱")
        XCTAssertEqual(try fridgeStore.loadAll().first?.fridge.name, "廚房冰箱")
        XCTAssertThrowsError(try directory.rename(first.id, to: String(repeating: "冰", count: 30))) {
            XCTAssertEqual($0 as? FridgeDirectoryError, .invalidName)
        }
        XCTAssertEqual(directory.fridges.first?.name, "廚房冰箱")
    }

    // 5
    func testSelectionPersistsAcrossLaunchesAndFallsBack() throws {
        let suite = "MultiFridgeTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let stored = UserDefaultsFridgeSelectionStore(defaults: UserDefaults(suiteName: suite)!)
        let directory = try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore, selection: stored)
        let second = try directory.create(name: "第二台")
        try directory.select(second.id)
        let relaunched = try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore,
                                             selection: UserDefaultsFridgeSelectionStore(defaults: UserDefaults(suiteName: suite)!))
        XCTAssertEqual(relaunched.selectedID, second.id)
        stored.selectedFridgeID = UUID() // stale preference
        XCTAssertEqual(relaunched.selectedID, first.id, "unknown selection falls back to the first fridge")
    }

    // 6, 7
    func testLayoutsAndDoorStatesAreIndependent() throws {
        let second = try directory.create(name: "第二台")
        var edited = second
        edited.cabinetCompartments.removeLast()
        try fridgeStore.saveLayout(edited)
        try fridgeStore.saveDoorState(.open, fridgeID: second.id)
        try directory.reload()
        XCTAssertEqual(directory.fridge(id: second.id)?.cabinetCompartments.count, first.cabinetCompartments.count - 1)
        XCTAssertEqual(directory.fridge(id: first.id)?.cabinetCompartments.count, 4, "first fridge untouched")
        XCTAssertEqual(directory.fridge(id: second.id)?.lastDoorState, .open)
        XCTAssertEqual(directory.fridge(id: first.id)?.lastDoorState, .closed)
    }

    // 8, 9
    func testCopiedLayoutHasNewIDsAndNoFood() throws {
        var customized = first
        customized.cabinetCompartments[1].storageType = .frozen
        customized.cabinetCompartments[1].name = "冷凍層"
        try fridgeStore.saveLayout(customized)
        try directory.reload()
        try addFood("牛奶", to: directory.fridges[0])

        let copy = try directory.create(name: "複製冰箱", copyingLayoutFrom: first.id)
        XCTAssertEqual(copy.allCompartments.map(\.name), customized.allCompartments.map(\.name))
        XCTAssertEqual(copy.allCompartments.map(\.storageType), customized.allCompartments.map(\.storageType))
        XCTAssertEqual(copy.allCompartments.map(\.normalizedFrame), customized.allCompartments.map(\.normalizedFrame))
        XCTAssertTrue(Set(copy.allCompartments.map(\.id)).isDisjoint(with: customized.allCompartments.map(\.id)), "never reuses IDs")
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertTrue(try foodStore.activeItems(fridgeID: copy.id).isEmpty, "food is never copied")
        XCTAssertEqual(try foodStore.activeItems(fridgeID: first.id).count, 1)
    }

    // 10, 11
    func testInventoryAndDashboardAreIsolatedPerFridge() throws {
        let second = try directory.create(name: "第二台")
        try addFood("牛奶", to: first, expiresIn: -1)
        try addFood("啤酒", to: second, expiresIn: -1)
        try addFood("可樂", to: second)
        let a = inventory(for: first), b = inventory(for: second)
        XCTAssertEqual(a.items.map(\.name), ["牛奶"])
        XCTAssertEqual(Set(b.items.map(\.name)), ["啤酒", "可樂"])
        XCTAssertTrue(a.search("啤").isEmpty, "search stays inside the fridge")
        XCTAssertEqual(a.contentSummary(for: second.cabinetCompartments[0].id).itemCount, 0)
        let dashboard = InventoryDashboardProvider(items: a.items, compartments: first.allCompartments,
                                                   aggregator: DashboardAggregator(), now: Date())
        XCTAssertEqual(dashboard.summary(for: .all).itemCount, 1)
        XCTAssertEqual(dashboard.summary(for: .refrigerated).expiredCount, 1)
        XCTAssertThrowsError(try a.add({ var d = FoodDraft(compartmentID: second.cabinetCompartments[0].id); d.name = "x"; return d }()),
                             "a compartment of another fridge is rejected") {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentNotFound)
        }
    }

    // 13, 14
    func testCrossFridgeMoveUpdatesOwnershipAtomically() throws {
        let second = try directory.create(name: "第二台")
        let milk = try addFood("牛奶", to: first)
        let a = inventory(for: first)
        XCTAssertThrowsError(try a.move(milk.id, to: first.cabinetCompartments[1].id, in: second), "compartment must belong to the destination") {
            XCTAssertEqual($0 as? FoodValidationError, .compartmentNotFound)
        }
        XCTAssertThrowsError(try a.move(milk.id, to: second.cabinetCompartments[1].id), "same-fridge move can't target another fridge")
        XCTAssertEqual(a.items.first?.fridgeID, first.id)

        try a.move(milk.id, to: second.cabinetCompartments[1].id, in: second)
        XCTAssertTrue(a.items.isEmpty)
        let moved = try XCTUnwrap(inventory(for: second).item(id: milk.id))
        XCTAssertEqual(moved.fridgeID, second.id)
        XCTAssertEqual(moved.compartmentID, second.cabinetCompartments[1].id)
        XCTAssertEqual(moved.storedAt, milk.storedAt, "same record, same dates")
    }

    // 15, 16
    func testDeletionIsBlockedByFoodAndPreservesHistory() throws {
        let second = try directory.create(name: "第二台")
        try directory.select(second.id)
        let leftover = try addFood("剩菜", to: second)
        XCTAssertThrowsError(try directory.delete(second.id)) {
            XCTAssertEqual($0 as? FridgeDirectoryError, .hasActiveFood(1))
        }
        XCTAssertEqual(directory.fridges.count, 2, "nothing deleted")
        let b = inventory(for: second)
        try b.markConsumed(leftover.id)
        let summary = try directory.deletionSummary(for: second.id)
        XCTAssertEqual(summary.activeFoodCount, 0)
        XCTAssertEqual(summary.historyCount, 1)
        XCTAssertEqual(summary.remainingFridge.id, first.id)

        try directory.delete(second.id)
        XCTAssertEqual(directory.fridges.map(\.id), [first.id])
        XCTAssertEqual(directory.selectedID, first.id, "selection moves to the remaining fridge")
        let a = inventory(for: first)
        let history = try a.historyItems()
        XCTAssertEqual(history.map(\.id), [leftover.id], "history kept in the remaining fridge")
        XCTAssertThrowsError(try a.restore(leftover.id)) {
            XCTAssertEqual($0 as? FoodValidationError, .restoreNeedsCompartment, "never restored into a wrong compartment")
        }
        XCTAssertEqual(try a.restore(leftover.id, to: first.cabinetCompartments[0].id).fridgeID, first.id)
        XCTAssertThrowsError(try directory.delete(first.id)) { XCTAssertEqual($0 as? FridgeDirectoryError, .lastFridge) }
    }

    // 17
    func testDeletionFailureLeavesEverythingInPlace() throws {
        let second = try directory.create(name: "第二台")
        try directory.select(second.id)
        fridgeStore.failWrites = true
        XCTAssertThrowsError(try directory.delete(second.id))
        XCTAssertEqual(directory.fridges.count, 2)
        XCTAssertEqual(directory.selectedID, second.id)
    }

    // 21
    func testFavoriteWithAnotherFridgesCompartmentIsNotApplied() throws {
        let second = try directory.create(name: "第二台")
        var draft = FoodDraft(now: Date())
        draft.apply(FoodTemplate(name: "優格", categoryID: "dairy", unit: "杯", preferredCompartmentID: second.cabinetCompartments[0].id),
                    validCompartmentIDs: Set(first.allCompartments.map(\.id)))
        XCTAssertNil(draft.compartmentID, "a stale / other-fridge compartment is never used")
        XCTAssertEqual(draft.name, "優格")
    }

    // 22
    func testLegacySingleFridgeDataIsKeptAsIs() throws {
        let legacy = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let old = FridgeFactory.makeDefault(name: "我的冰箱")
        let context = ModelContext(legacy)
        context.insert(FridgeRecord(id: old.id, name: old.name, templateID: old.templateID,
                                    lastDoorStateRaw: DoorState.open.rawValue, layoutData: try StoredLayout.encode(old)))
        try context.save()
        let foods = SwiftDataFoodStore(container: legacy)
        let now = Date()
        let milk = FoodItem(id: UUID(), name: "牛奶", categoryID: "dairy", quantity: 1, unit: "瓶", storedAt: now,
                            fridgeID: old.id, compartmentID: old.cabinetCompartments[0].id, createdAt: now, updatedAt: now)
        try foods.upsert(milk)

        let directory = try FridgeDirectory(fridgeStore: SwiftDataFridgeStore(container: legacy), foodStore: foods,
                                            selection: InMemoryFridgeSelectionStore())
        XCTAssertEqual(directory.fridges.count, 1, "no extra default fridge")
        XCTAssertEqual(directory.selected.fridge.id, old.id)
        XCTAssertEqual(directory.selected.fridge.allCompartments.map(\.id), old.allCompartments.map(\.id))
        XCTAssertEqual(directory.selected.fridge.lastDoorState, .open)
        XCTAssertEqual(try foods.activeItems(fridgeID: old.id), [milk])
    }
}

/// Reminders, notifications, widgets and links across two fridges.
@MainActor
final class MultiFridgeIntegrationTests: XCTestCase {
    private var session: AppSession!
    private var first: Fridge!
    private var second: Fridge!

    override func setUpWithError() throws {
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        self.session = session
        first = session.directory.fridges[0]
        second = try session.directory.create(name: "儲藏室冰箱")
    }

    private func inventory(_ fridge: Fridge) -> FoodInventoryService {
        FoodInventoryService(store: session.foodStore, fridgeID: fridge.id, compartments: { fridge.allCompartments })
    }

    @discardableResult
    private func add(_ name: String, to fridge: Fridge, expiresIn days: Int) throws -> FoodItem {
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = name
        draft.expirationDate = Date().addingTimeInterval(Double(days) * 86_400)
        return try inventory(fridge).add(draft)
    }

    private func makeHome(_ session: AppSession) -> FridgeHomeViewController {
        let home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient(),
                                            widgetPublisher: WidgetSnapshotPublisher(file: nil, reloader: CountingReloader()))
        home.loadViewIfNeeded()
        return home
    }

    // 12
    func testReminderCenterScopes() throws {
        try add("牛奶", to: first, expiresIn: -1)
        try add("啤酒", to: second, expiresIn: 1)
        let home = makeHome(session)
        let data = try XCTUnwrap(home.allFridgesData())
        let center = ReminderCenterViewController(inventory: inventory(first), compartments: { [first] in first!.allCompartments })
        center.allFridges = {
            .init(items: data.items, compartments: data.compartments,
                  names: Dictionary(data.fridges.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        center.loadViewIfNeeded()
        XCTAssertEqual(center.entries.map(\.item.name), ["牛奶"], "default: current fridge only")
        XCTAssertNil(center.entries.first?.fridgeName)
        center.select(scope: .allFridges)
        XCTAssertEqual(Set(center.entries.map(\.item.name)), ["牛奶", "啤酒"])
        XCTAssertEqual(center.entries.first { $0.item.name == "啤酒" }?.locationText, "儲藏室冰箱 · 櫃內 · 上層",
                       "every row shows which fridge it's in")
        center.select(storage: .frozen)
        XCTAssertTrue(center.entries.isEmpty, "storage filter still applies in the all-fridges scope")
    }

    // 18
    func testNotificationsCoverBothFridgesAndSurviveSwitching() async throws {
        let milk = try add("牛奶", to: first, expiresIn: 5)
        let beer = try add("啤酒", to: second, expiresIn: 5)
        let client = FakeNotificationClient()
        var readable = true
        let home = makeHome(session)
        let coordinator = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(),
                                                  snapshot: { readable ? home.allFridgesData().map { ($0.items, $0.compartments) } : nil })
        await coordinator.reschedule()
        let ids = Set(client.pending.keys)
        XCTAssertTrue(ids.contains(PlannedNotification.identifier(foodID: milk.id, kind: .expiration)))
        XCTAssertTrue(ids.contains(PlannedNotification.identifier(foodID: beer.id, kind: .expiration)))
        XCTAssertEqual(client.pending[PlannedNotification.identifier(foodID: beer.id, kind: .expiration)]?.fridgeID, second.id)

        // Viewing the other fridge plans the same set (nothing cancelled).
        let otherHome = makeHome(try session.selecting(second.id))
        let switched = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(),
                                               snapshot: { otherHome.allFridgesData().map { ($0.items, $0.compartments) } })
        await switched.reschedule()
        XCTAssertEqual(Set(client.pending.keys), ids)

        readable = false
        await coordinator.reschedule()
        XCTAssertEqual(Set(client.pending.keys), ids, "a failed read never cancels reminders")

        let planned = try XCTUnwrap(client.pending[PlannedNotification.identifier(foodID: beer.id, kind: .expiration)])
        let router = AppNotificationRouter()
        router.handle(userInfo: NotificationPayload.userInfo(for: planned))
        XCTAssertEqual(router.pending, .link(AppDeepLink(.food(beer.id), refrigeratorID: second.id)))
    }

    // 19
    func testWidgetSnapshotKeepsFridgesSeparate() throws {
        try add("牛奶", to: first, expiresIn: 1)
        try add("啤酒", to: second, expiresIn: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WidgetSnapshotFile(url: directory.appendingPathComponent("s.json"))
        let data = try XCTUnwrap(makeHome(session).allFridgesData())
        let publisher = WidgetSnapshotPublisher(file: file, reloader: CountingReloader())
        publisher.publish(fridges: data.fridges, items: data.items, selectedFridgeID: first.id)
        publisher.waitUntilIdle()
        let bundle = try XCTUnwrap(file.read())
        XCTAssertEqual(bundle.fridges.map(\.refrigeratorID), [first.id, second.id])
        XCTAssertEqual(bundle.snapshot(for: first.id)?.urgentFoodItems.map(\.name), ["牛奶"])
        XCTAssertEqual(bundle.snapshot(for: second.id)?.urgentFoodItems.map(\.name), ["啤酒"])
        XCTAssertEqual(bundle.snapshot(for: second.id)?.refrigeratorName, "儲藏室冰箱")
        XCTAssertEqual(bundle.snapshot(for: nil)?.refrigeratorID, first.id, "unconfigured widgets follow the app")
        XCTAssertEqual(bundle.snapshot(for: UUID())?.refrigeratorID, first.id, "a deleted fridge falls back safely")
    }

    // 20
    func testDeepLinksToAnotherFridgeSwitchFirst() throws {
        let home = makeHome(session)
        var switched: [(UUID, ExternalRoute?)] = []
        home.onSwitchFridge = { switched.append(($0, $1)) }
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: second.cabinetCompartments[1].id), refrigeratorID: second.id)))
        XCTAssertEqual(switched.first?.0, second.id)
        XCTAssertEqual(switched.first?.1, .link(AppDeepLink(.quickAdd(compartmentID: second.cabinetCompartments[1].id))))

        home.handle(.link(AppDeepLink(.food(UUID()), refrigeratorID: UUID())))
        XCTAssertEqual(switched.count, 1, "unknown fridge → no switch, stays on the current fridge")

        // On the target fridge, the quick-add compartment is validated against that fridge.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let target = makeHome(try session.selecting(second.id))
        window.rootViewController = UINavigationController(rootViewController: target)
        window.makeKeyAndVisible()
        target.openQuickAdd(preferredCompartmentID: first.cabinetCompartments[0].id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let editor = (target.navigationController?.presentedViewController as? UINavigationController)?.topViewController as? FoodEditorViewController
        XCTAssertNotNil(editor)
        XCTAssertNotEqual(editor?.draft.compartmentID, first.cabinetCompartments[0].id, "another fridge's compartment is never used")
        window.rootViewController?.dismiss(animated: false)
    }

    func testFridgeMenuOffersAddUntilLimit() throws {
        let home = makeHome(session)
        let elements = home.fridgeMenuElements()
        let names = (elements.first as? UIMenu)?.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(names, ["我的冰箱", "儲藏室冰箱"])
        let add = (elements.last as? UIMenu)?.children.compactMap { $0 as? UIAction }.first { $0.title == "新增冰箱" }
        XCTAssertEqual(add?.attributes.contains(.disabled), true)
        XCTAssertEqual(add?.subtitle, "目前最多可建立 2 台冰箱。")
    }
}

/// Monetization suspended (Phase 4.1).
@MainActor
final class MonetizationSuspensionTests: XCTestCase {
    // 23, 24, 25
    func testSuspendedPolicyHidesPaidUIAndNeverCreatesAds() async throws {
        XCTAssertFalse(MonetizationPolicy.current.isEnabled)
        let store = MockStoreClient()
        store.entitlements = [StoreTransactionInfo(productID: StoreProducts.premium, isVerified: true, revocationDate: nil)]
        var adsCreated = 0
        let services = MonetizationServices.make(policy: .current, mode: .persistent, store: store, makeAds: { entitlements in
            adsCreated += 1
            return AdsCoordinator(entitlements: entitlements, consent: FakeConsent(), sdk: FakeAdSDK())
        })
        XCTAssertNil(services.ads, "no ad coordinator → no SDK start, no requests")
        XCTAssertEqual(adsCreated, 0)
        XCTAssertNil(services.entitlementsForUI, "no paid entry points")
        let observer = try XCTUnwrap(services.entitlementObserver, "StoreKit observation keeps running")
        await observer.refresh()
        XCTAssertEqual(observer.purchasedState, .premium, "an existing purchase is preserved and reported truthfully")

        let freeStore = MockStoreClient()
        let free = MonetizationServices.make(policy: .current, mode: .persistent, store: freeStore)
        await free.entitlementObserver?.refresh()
        XCTAssertEqual(free.entitlementObserver?.purchasedState, .free, "free users are never granted Premium")

        let enabled = MonetizationServices.make(policy: MonetizationPolicy(isEnabled: true), mode: .persistent, store: MockStoreClient(),
                                                makeAds: { AdsCoordinator(entitlements: $0, consent: FakeConsent(), sdk: FakeAdSDK()) })
        XCTAssertNotNil(enabled.ads, "turning the switch back on restores Phase 4 behaviour")
        XCTAssertEqual(MonetizationServices.make(policy: .current, mode: .inMemoryForTesting).entitlementObserver == nil, true)
    }

    func testSettingsAndHomeShowNoPaidEntryPoints() throws {
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        let home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient(),
                                            widgetPublisher: WidgetSnapshotPublisher(file: nil, reloader: CountingReloader()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: home)
        window.makeKeyAndVisible()
        XCTAssertFalse(home.view.allSubviews.contains { $0 is BannerAdContainerView }, "no banner slot at all")

        home.openSettings()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let settings = try XCTUnwrap(home.navigationController?.topViewController as? SettingsViewController)
        settings.loadViewIfNeeded()
        let table = settings.tableView!
        var texts: [String] = []
        for section in 0..<settings.numberOfSections(in: table) {
            for row in 0..<settings.tableView(table, numberOfRowsInSection: section) {
                let cell = settings.tableView(table, cellForRowAt: IndexPath(row: row, section: section))
                if let text = (cell.contentConfiguration as? UIListContentConfiguration)?.text { texts.append(text) }
            }
        }
        XCTAssertTrue(texts.contains("管理冰箱"))
        for paid in ["升級完整版", "恢復購買", "已解鎖完整版", "廣告與隱私設定", "顯示廣告"] {
            XCTAssertFalse(texts.contains(paid), paid)
        }
    }
}
