import CloudKit
import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5D-5: reminders, widgets, backups and the fridge selector with shared fridges. Each device schedules and
/// publishes only from what it may read; backups never contain or overwrite shared fridges.
@MainActor
final class SharingIntegrationTests: XCTestCase {
    private final class IdleCloud: SharingCloud {
        var isReady = true
        func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {}
        func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) { throw SharingServiceError.shareFailed }
        func rollback(fridgeID: UUID) {}
    }

    private let owner = "_owner"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var work: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("SharingIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SharingIntegrationTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private struct World {
        let container: ModelContainer
        let sharing: SharingService
        let session: AppSession
        let sharedFridge: Fridge
        let sharedFood: FoodItem
    }

    /// One personal fridge, plus a joined shared fridge holding milk that expires tomorrow.
    private func makeWorld() throws -> World {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: container).loadAll() // first launch: the default personal fridge
        let store = SharedStore(container: try SharedStore.makeContainer(inMemory: true))
        let sharing = SharingService(policy: SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false,
                                                           accessRequestsSupported: true),
                                     inventory: SharedInventory(store: store), cloud: IdleCloud(),
                                     personal: SwiftDataFridgeStore(container: container), hasPremium: { false }, snapshots: nil,
                                     defaults: defaults)
        let fridge = FridgeFactory.makeDefault(name: "爸媽家")
        let now = Date()
        let milk = FoodItem(id: UUID(), name: "鮮奶", categoryID: "dairy", quantity: 2, unit: "瓶", storedAt: now,
                            expirationDate: now.addingTimeInterval(86_400), storageReminderDays: nil, fridgeID: fridge.id,
                            compartmentID: fridge.cabinetCompartments[0].id, createdAt: now, updatedAt: now, consumedAt: nil)
        let fields = SharedFoodFields(id: milk.id, fridgeID: fridge.id, compartmentID: milk.compartmentID, name: milk.name,
                                      categoryID: milk.categoryID, baseQuantity: 2, foldedOpIDs: [], unit: milk.unit,
                                      storedAt: now, expirationDate: milk.expirationDate, storageReminderDays: nil,
                                      createdAt: now, updatedAt: now, consumedAt: nil)
        try store.apply(modifications: [
            SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                        layoutData: try StoredLayout.encode(fridge), createdAt: date, updatedAt: date),
                                     ownerName: owner, systemFields: nil),
            SharedRecordCoder.encode(fields, ownerName: owner, systemFields: nil)
        ], deletions: [], scope: .shared)
        let session = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: sharing).get()
        return World(container: container, sharing: sharing, session: session, sharedFridge: fridge, sharedFood: milk)
    }

    private func home(for session: AppSession, client: FakeNotificationClient, file: WidgetSnapshotFile) -> (FridgeHomeViewController, WidgetSnapshotPublisher) {
        let publisher = WidgetSnapshotPublisher(file: file, reloader: CountingReloader())
        let home = FridgeHomeViewController(session: session, notificationClient: client, widgetPublisher: publisher)
        home.loadViewIfNeeded()
        return (home, publisher)
    }

    // MARK: Reminders and widgets

    func testJoinedFridgeGetsRemindersAndWidgetOnThisDevice() async throws {
        let world = try makeWorld()
        XCTAssertEqual(world.session.directory.fridges.count, 2)
        let client = FakeNotificationClient()
        let file = WidgetSnapshotFile(url: work.appendingPathComponent("widget.json"))
        let (home, publisher) = home(for: world.session, client: client, file: file)
        _ = await home.syncAfterRestore()
        XCTAssertTrue(client.pending.values.contains { $0.foodID == world.sharedFood.id }, "shared food is reminded like any other")
        publisher.waitUntilIdle()
        XCTAssertTrue(file.read()?.fridges.contains { $0.refrigeratorID == world.sharedFridge.id } ?? false)
    }

    func testRevokedFridgeDropsItsRemindersAndWidget() async throws {
        let world = try makeWorld()
        let client = FakeNotificationClient()
        let file = WidgetSnapshotFile(url: work.appendingPathComponent("widget.json"))
        _ = await home(for: world.session, client: client, file: file).0.syncAfterRestore()
        XCTAssertTrue(client.pending.values.contains { $0.foodID == world.sharedFood.id })

        // The owner removed this member: the zone disappears.
        try world.sharing.inventory.store.zoneWasDeleted(SharedZone.id(fridgeID: world.sharedFridge.id, kind: .inventory, ownerName: owner),
                                                         scope: .shared)
        let rebuilt = try AppBootstrap.makeSession(container: world.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: world.sharing).get()
        XCTAssertEqual(rebuilt.directory.fridges.count, 1, "an unavailable fridge can't be opened")
        let (home, publisher) = home(for: rebuilt, client: client, file: file)
        _ = await home.syncAfterRestore()
        XCTAssertFalse(client.pending.values.contains { $0.foodID == world.sharedFood.id }, "no reminder from revoked data")
        publisher.waitUntilIdle()
        XCTAssertFalse(file.read()?.fridges.contains { $0.refrigeratorID == world.sharedFridge.id } ?? true)
    }

    func testRefreshAfterSharedChangeUpdatesReminders() async throws {
        let world = try makeWorld()
        let client = FakeNotificationClient()
        let (home, _) = home(for: world.session, client: client, file: WidgetSnapshotFile(url: work.appendingPathComponent("w.json")))
        _ = await home.syncAfterRestore()
        try world.sharing.inventory.delete(id: world.sharedFood.id)
        home.refreshSharedIntegrations()
        _ = await home.syncAfterRestore()
        XCTAssertFalse(client.pending.values.contains { $0.foodID == world.sharedFood.id })
    }

    // MARK: Backups

    func testExportNeverContainsSharedFridges() throws {
        let world = try makeWorld()
        let backup = try world.session.makeBackupService(defaults: defaults).makeBackup()
        XCTAssertFalse(backup.fridges.contains { $0.id == world.sharedFridge.id })
        XCTAssertFalse(backup.foods.contains { $0.id == world.sharedFood.id })
        XCTAssertEqual(backup.fridges.count, 1)
    }

    func testExportWithOnlySharedFridgesExplainsWhy() throws {
        let world = try makeWorld()
        let personal = SwiftDataFridgeStore(container: world.container)
        for result in try personal.loadExisting() { try personal.removeFridgeAfterSharing(result.fridge.id) }
        XCTAssertThrowsError(try world.session.makeBackupService(defaults: defaults).makeBackup()) {
            XCTAssertEqual($0 as? BackupError, .onlySharedFridges)
        }
    }

    func testRestoreNeverTouchesSharedFridges() throws {
        let world = try makeWorld()
        let service = world.session.makeBackupService(defaults: defaults)
        let backup = try service.makeBackup()
        try service.restore(backup)
        XCTAssertEqual(world.sharing.inventory.ownership(of: world.sharedFridge.id), .sharedParticipant)
        XCTAssertEqual(try world.sharing.inventory.items(fridgeID: world.sharedFridge.id).map(\.id), [world.sharedFood.id])
    }

    func testRestoreCantOverwriteASharedFridge() throws {
        let world = try makeWorld()
        let service = world.session.makeBackupService(defaults: defaults)
        var backup = try service.makeBackup()
        // E.g. the "before sharing" snapshot: it still has the fridge that is now shared.
        backup.fridges[0] = BackupFridge(Fridge(id: world.sharedFridge.id, name: "爸媽家", templateID: world.sharedFridge.templateID,
                                                lastDoorState: .closed, cabinetCompartments: world.sharedFridge.cabinetCompartments,
                                                doorCompartments: world.sharedFridge.doorCompartments), createdAt: date)
        backup.foods = []
        backup.magnets = []
        XCTAssertThrowsError(try service.checkRestorable(backup)) { XCTAssertEqual($0 as? BackupError, .sharedFridgeConflict("爸媽家")) }
        XCTAssertThrowsError(try service.restore(backup))
        XCTAssertEqual(world.session.directory.fridges.count, 2, "nothing changed")
    }

    func testRestoreRespectsTheLimitWithSharedFridges() throws {
        let world = try makeWorld()
        let service = world.session.makeBackupService(defaults: defaults)
        var backup = try service.makeBackup()
        backup.fridges.append(BackupFridge(FridgeFactory.makeDefault(name: "儲藏室"), createdAt: date))
        XCTAssertThrowsError(try service.checkRestorable(backup)) { XCTAssertEqual($0 as? BackupError, .sharedLimit(sharedCount: 1)) }
        XCTAssertEqual(BackupError.sharedLimit(sharedCount: 1).message.contains("1 台共享冰箱"), true)
    }

    // MARK: Selector

    func testSelectorLabelsSharedAndWaitingEntries() async throws {
        let world = try makeWorld()
        try world.sharing.inventory.store.addInvitation(url: URL(string: "https://www.icloud.com/share/waiting")!)
        let (home, _) = home(for: world.session, client: FakeNotificationClient(),
                             file: WidgetSnapshotFile(url: work.appendingPathComponent("w.json")))
        let actions = home.fridgeMenuElements().compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap { $0 as? UIAction }
        let shared = try XCTUnwrap(actions.first { $0.title == "爸媽家" })
        XCTAssertEqual(shared.subtitle, "參與共享")
        let waiting = try XCTUnwrap(actions.first { $0.subtitle == "等待主人同意" })
        XCTAssertTrue(waiting.attributes.contains(.disabled), "a waiting request can't be opened")
        let personal = try XCTUnwrap(actions.first { $0.title == world.session.loadResult.fridge.name && $0.title != "爸媽家" })
        XCTAssertNil(personal.subtitle)
        XCTAssertFalse(world.session.directory.canAddFridge, "personal + joined (+ waiting) fill both slots")
    }

    func testSharedStoreIsSeparateFromThePersonalSchema() throws {
        let shared = try SharedStore.makeContainer(inMemory: true)
        let names = Set(shared.schema.entities.map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["FridgeRecord", "FoodItemRecord", "MagnetRecord", "MagnetImageRecord"]))
        // Personal backups and SwiftData mirroring never see shared records.
        XCTAssertEqual(Set(SwiftDataFridgeStore.schema.entities.map(\.name)),
                       ["FridgeRecord", "FoodItemRecord", "MagnetRecord", "MagnetImageRecord"])
    }
}
