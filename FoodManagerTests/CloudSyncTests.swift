import SQLite3
import SwiftData
import UIKit
import XCTest
@testable import FoodManager

final class FakeKeyValueStore: KeyValueCloudStore {
    var values: [String: Any] = [:]
    var syncCount = 0
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { syncCount += 1; return true }
}

struct FakeAccountProvider: CloudAccountProvider {
    var state: CloudAccountState
    var fingerprint: String?
    func accountState() async -> CloudAccountState { state }
    func accountFingerprint() async -> String? { fingerprint }
}

/// Phase 4.4: CloudKit-ready persistence, safe migration, reconciliation of synced data, accounts (policy A),
/// synced magnet photos, preference sync, UI refresh and manual-backup regressions. CloudKit itself is never
/// contacted here: these tests prove the local behaviour around it, not end-to-end iCloud delivery.
final class CloudSyncTests: XCTestCase {
    private var work: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        suite = "CloudSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: Helpers

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext) in the test bundle")
    }

    /// A copy of the real Phase 4.3 store (fixtures are never opened in place).
    private func preCloudStoreCopy() throws -> (store: URL, images: URL) {
        let store = work.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture("precloud-4.3", "store"), to: store)
        let images = work.appendingPathComponent("Magnets", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let expected = try expectedBackup()
        for id in Set(expected.allMagnets.compactMap(\.localImageID)) {
            try FileManager.default.copyItem(at: fixture(id.uuidString, "img"), to: images.appendingPathComponent("\(id.uuidString).img"))
        }
        return (store, images)
    }

    private func expectedBackup() throws -> FoodManagerBackup {
        try BackupCoding.decoder().decode(FoodManagerBackup.self, from: Data(contentsOf: fixture("precloud-4.3-expected", "json")))
    }

    private func settings() -> CloudSyncSettings { CloudSyncSettings(defaults: defaults) }

    /// The fixture was exported with the first fridge selected and no favorites.
    private func prefs() -> PreferencesBackupStore {
        let selection = InMemoryFridgeSelectionStore()
        selection.selectedFridgeID = try? expectedBackup().preferences.selectedFridgeID
        return UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection)
    }

    private func backupService(_ container: ModelContainer, images: MagnetImageStore? = nil,
                               selection: FridgeSelectionStore = InMemoryFridgeSelectionStore()) -> BackupService {
        BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                      preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection),
                      magnetImages: images, recoveryDirectory: nil, applicationVersion: "test")
    }

    /// Simulates CloudKit delivering another device's rows: the same app IDs, inserted as new rows.
    private func deliver(_ fridges: [Fridge] = [], createdAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000),
                         foods: [FoodItem] = [], magnets: [FridgeMagnet] = [], images: [UUID: Data] = [:],
                         into container: ModelContainer) throws {
        let context = ModelContext(container)
        for fridge in fridges {
            context.insert(FridgeRecord(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                        lastDoorStateRaw: "closed", layoutData: try StoredLayout.encode(fridge), createdAt: createdAt))
        }
        for food in foods { context.insert(FoodItemRecord(food)) }
        for magnet in magnets { context.insert(MagnetRecord(magnet)) }
        for (id, data) in images { context.insert(MagnetImageRecord(id: id, data: data)) }
        try context.save()
    }

    private func food(_ name: String, in fridge: Fridge, compartment: Int = 0, updated: TimeInterval = 800_000_000,
                      id: UUID = UUID(), quantity: Decimal = 1, consumed: Date? = nil) -> FoodItem {
        FoodItem(id: id, name: name, categoryID: FoodCategoryCatalog.otherID, quantity: quantity, unit: "個",
                 storedAt: Date(timeIntervalSinceReferenceDate: 799_000_000), expirationDate: nil, storageReminderDays: nil,
                 fridgeID: fridge.id, compartmentID: fridge.cabinetCompartments[compartment].id,
                 createdAt: Date(timeIntervalSinceReferenceDate: 799_000_000), updatedAt: Date(timeIntervalSinceReferenceDate: updated),
                 consumedAt: consumed)
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { _ in
            UIColor.systemPink.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }.pngData()!
    }

    private func uniqueIndexes(in store: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return ["<open failed>"] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='index' AND sql LIKE 'CREATE UNIQUE%' AND tbl_name IN ('ZFRIDGERECORD','ZFOODITEMRECORD','ZMAGNETRECORD')", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
        return names
    }

    // MARK: 1, 25 — migration preparation and interrupted migration

    func testPreSyncPreparationProtectsTheRealPreCloudStore() throws {
        let (store, images) = try preCloudStoreCopy()
        let originalBytes = try Data(contentsOf: store)
        XCTAssertFalse(uniqueIndexes(in: store).isEmpty, "the Phase 4.3 store has unique indexes")
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        let settings = settings()
        let outcome = CloudSyncPreparation.prepareIfNeeded(storeURL: store, settings: settings, snapshots: snapshots,
                                                           magnetImageDirectory: images,
                                                           preferences: prefs())
        XCTAssertEqual(outcome, .ready)
        XCTAssertTrue(settings.isPreparedForCloud)
        // 1. Raw copy of the untouched store.
        let rawCopy = snapshots.directory.appendingPathComponent("PreCloud-Store/default.store")
        XCTAssertEqual(try Data(contentsOf: rawCopy), originalBytes, "byte-identical pre-migration copy")
        // 2. Verified JSON backup with exactly the pre-cloud content.
        let snapshot = try BackupValidator.decode(Data(contentsOf: snapshots.url(for: .preCloud)))
        XCTAssertTrue(BackupService.canonical(snapshot).hasSameContent(as: BackupService.canonical(try expectedBackup())))
        // 3. The upgraded store has no unique constraints and the photo has a synced record.
        XCTAssertTrue(uniqueIndexes(in: store).isEmpty, "unique indexes removed by the lightweight migration")
        let container = try SwiftDataFridgeStore.makeContainer(url: store)
        XCTAssertEqual(try SwiftDataMagnetStore(container: container).storedImageIDs().count, 1)
        // A second copy of a record (as CloudKit may deliver) can be stored after the upgrade.
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        try deliver([fridge], into: container)
        XCTAssertEqual(try SwiftDataFridgeStore(container: container).loadAll().count, 2, "shown once per ID")
        // Running again does nothing.
        XCTAssertEqual(CloudSyncPreparation.prepareIfNeeded(storeURL: store, settings: settings, snapshots: snapshots,
                                                            magnetImageDirectory: images), .ready)
    }

    func testInterruptedPreparationDeletesNothingAndKeepsSyncOff() throws {
        let (store, images) = try preCloudStoreCopy()
        let before = try Data(contentsOf: store)
        struct Interrupted: Error {}
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        let settings = settings()
        let outcome = CloudSyncPreparation.prepareIfNeeded(storeURL: store, settings: settings, snapshots: snapshots,
                                                           magnetImageDirectory: images, openLocal: { _ in throw Interrupted() })
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(settings.isPreparedForCloud, "sync stays off until preparation succeeds")
        XCTAssertEqual(try Data(contentsOf: store), before, "store untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshots.directory.appendingPathComponent("PreCloud-Store/default.store").path))
        // The next attempt succeeds and everything is still there.
        XCTAssertEqual(CloudSyncPreparation.prepareIfNeeded(storeURL: store, settings: settings, snapshots: snapshots,
                                                            magnetImageDirectory: images, preferences: prefs()), .ready)
        let container = try SwiftDataFridgeStore.makeContainer(url: store)
        XCTAssertTrue(BackupService.canonical(try backupService(container, images: MagnetImageStore(directory: images)).makeBackup())
            .hasSameContent(as: BackupService.canonical(try expectedBackup())))
    }

    func testFreshInstallNeedsNoPreparationAndFailedSnapshotKeepsThePreviousOne() throws {
        let settings = settings()
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        XCTAssertEqual(CloudSyncPreparation.prepareIfNeeded(storeURL: work.appendingPathComponent("none.store"), settings: settings,
                                                            snapshots: snapshots, magnetImageDirectory: work), .ready)
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        let good = try backupService(container).makeBackup()
        try snapshots.write(good, kind: .local)
        var broken = good
        broken.fridges = [] // invalid → verification fails → previous file kept
        XCTAssertThrowsError(try snapshots.write(broken, kind: .local))
        XCTAssertEqual(try BackupValidator.decode(Data(contentsOf: snapshots.url(for: .local))).fridges.count, 1)
    }

    // MARK: 2, 3, 4 — preservation

    func testMigratedStorePreservesBothFridgesAndAllIDs() throws {
        let (store, images) = try preCloudStoreCopy()
        let expected = try expectedBackup()
        let container = try SwiftDataFridgeStore.makeContainer(url: store)
        let session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(session.directory.fridges.map(\.id), expected.fridges.map(\.id), "no default fridge added")
        XCTAssertEqual(session.directory.fridges.flatMap(\.allCompartments).map(\.id),
                       expected.fridges.flatMap { $0.allCompartments.map(\.id) }, "compartment IDs kept")
        XCTAssertEqual(session.directory.fridges[0].cabinetCompartments[3].storageType, .frozen)
        let stored = try backupService(container, images: MagnetImageStore(directory: images)).makeBackup()
        XCTAssertEqual(Set(stored.foods.map(\.id)), Set(expected.foods.map(\.id)))
        XCTAssertEqual(stored.foods.filter { $0.consumedAt != nil }.count, 1, "history kept")
        XCTAssertEqual(stored.allMagnets.sorted { $0.zIndex < $1.zIndex }.map(\.id),
                       expected.allMagnets.sorted { $0.zIndex < $1.zIndex }.map(\.id), "magnet order kept")
        XCTAssertTrue(BackupService.canonical(stored).hasSameContent(as: BackupService.canonical(expected)))
    }

    func testExistingSingleFridgeIsKept() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let mine = FridgeFactory.makeDefault() // a pre-4.4 install: random ID
        try SwiftDataFridgeStore(container: container).create(mine)
        let session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(session.directory.fridges.map(\.id), [mine.id])
        XCTAssertEqual(try AppBootstrap.makeSession(container: container, mode: .persistent,
                                                    selection: InMemoryFridgeSelectionStore()).get().directory.fridges.count, 1)
    }

    // MARK: 5, 24 — no extra fridges

    func testTwoNewDevicesShareOneDefaultFridge() throws {
        let deviceA = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let deviceB = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let a = try SwiftDataFridgeStore(container: deviceA).loadAll()[0].fridge
        let b = try SwiftDataFridgeStore(container: deviceB).loadAll()[0].fridge
        XCTAssertEqual(a, b, "same fixed IDs on every new install")
        try deliver([b], into: deviceA) // B's row arrives on A
        XCTAssertEqual(try SwiftDataFridgeStore(container: deviceA).loadAll().map(\.fridge.id), [a.id])
        XCTAssertEqual(try ModelContext(deviceA).fetchCount(FetchDescriptor<FridgeRecord>()), 2, "rows kept, shown once")
    }

    func testNewDeviceDropsItsUnusedDefaultWhenExistingFridgesArrive() throws {
        let newDevice = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: newDevice).loadAll() // placeholder, created "now"
        let home = FridgeFactory.makeDefault(name: "我的冰箱"), pantry = FridgeFactory.makeDefault(name: "儲藏室")
        try deliver([home, pantry], createdAt: Date(timeIntervalSinceReferenceDate: 600_000_000), into: newDevice)
        let report = try SyncReconciler(container: newDevice).run()
        XCTAssertTrue(report.removedPlaceholderFridge)
        XCTAssertFalse(report.exceedsFridgeLimit)
        let session = try AppBootstrap.makeSession(container: newDevice, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(Set(session.directory.fridges.map(\.id)), [home.id, pantry.id], "2 fridges, not 3")
    }

    // MARK: 9 — reconciliation never removes user data

    func testPlaceholderIsKeptWhenUsedOrWhenFridgesAreNewer() throws {
        func newDevice() throws -> (ModelContainer, Fridge) {
            let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
            return (container, try SwiftDataFridgeStore(container: container).loadAll()[0].fridge)
        }
        let older = Date(timeIntervalSinceReferenceDate: 600_000_000)
        // Used: food in it.
        var (c1, p1) = try newDevice()
        try SwiftDataFoodStore(container: c1).upsert(food("牛奶", in: p1))
        try deliver([FridgeFactory.makeDefault()], createdAt: older, into: c1)
        XCTAssertFalse(try SyncReconciler(container: c1).run().removedPlaceholderFridge)
        // Used: renamed.
        (c1, p1) = try newDevice()
        try SwiftDataFridgeStore(container: c1).rename(fridgeID: p1.id, to: "廚房")
        try deliver([FridgeFactory.makeDefault()], createdAt: older, into: c1)
        XCTAssertFalse(try SyncReconciler(container: c1).run().removedPlaceholderFridge)
        // A fridge the user created afterwards on this device is not a reason to remove it.
        (c1, _) = try newDevice()
        try SwiftDataFridgeStore(container: c1).create(FridgeFactory.makeDefault(name: "儲藏室"))
        XCTAssertFalse(try SyncReconciler(container: c1).run().removedPlaceholderFridge)
        XCTAssertEqual(try SwiftDataFridgeStore(container: c1).loadAll().count, 2)
    }

    func testOverLimitIsReportedAndMergedWithoutLosingAnything() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let a = FridgeFactory.makeDefault(name: "A"), b = FridgeFactory.makeDefault(name: "B"), c = FridgeFactory.makeDefault(name: "C")
        try deliver([a, b, c], into: container)
        let milk = food("牛奶", in: c), jam = food("果醬", in: c, consumed: Date(timeIntervalSinceReferenceDate: 801_000_000))
        let magnet = FridgeMagnet(id: UUID(), fridgeID: c.id, source: .builtIn, builtInAssetID: "daisy", localImageID: nil,
                                  centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, rotation: 0, zIndex: 0, createdAt: .now, updatedAt: .now)
        try deliver(foods: [milk, jam], magnets: [magnet], into: container)
        XCTAssertTrue(try SyncReconciler(container: container).run().exceedsFridgeLimit)
        let session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(session.directory.fridges.count, 3, "never hidden or dropped")
        XCTAssertTrue(session.directory.exceedsLimit)
        XCTAssertFalse(session.directory.canAddFridge)
        let target = a.cabinetCompartments[1].id
        try session.directory.merge(c.id, into: a.id, compartmentID: target)
        XCTAssertEqual(session.directory.fridges.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(try session.foodStore.activeItems(fridgeID: a.id).map(\.id), [milk.id])
        XCTAssertEqual(try session.foodStore.activeItems(fridgeID: a.id).first?.compartmentID, target)
        XCTAssertEqual(try session.foodStore.consumedItems(fridgeID: a.id).map(\.id), [jam.id])
        XCTAssertEqual(try session.magnets.magnets(fridgeID: a.id).map(\.id), [magnet.id])
        XCTAssertThrowsError(try session.directory.merge(b.id, into: b.id, compartmentID: target))
    }

    // MARK: 7, 8 — offline (local-first)

    func testFoodIsCreatedAndEditedWithoutICloud() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true) // no CloudKit, like offline / signed out
        let session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        let fridge = session.loadResult.fridge
        let inventory = FoodInventoryService(store: session.foodStore, fridgeID: fridge.id, compartments: { fridge.allCompartments })
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = "豆腐"
        let item = try inventory.add(draft)
        var edited = draft
        edited.quantity = 3
        edited.compartmentID = fridge.cabinetCompartments[2].id
        try inventory.update(item.id, with: edited)
        try inventory.markConsumed(item.id)
        try inventory.restore(item.id, to: fridge.cabinetCompartments[1].id)
        let stored = try XCTUnwrap(try SwiftDataFoodStore(container: container).activeItems(fridgeID: fridge.id).first)
        XCTAssertEqual(stored.quantity, 3)
        XCTAssertEqual(stored.compartmentID, fridge.cabinetCompartments[1].id)
        let monitor = CloudSyncMonitor(center: NotificationCenter())
        monitor.updateAccount(.noAccount)
        XCTAssertEqual(monitor.status(enabled: true).title, "iCloud 無法使用")
        XCTAssertTrue(monitor.status(enabled: true).detail?.contains("資料仍保存在這台裝置上") == true)
    }

    // MARK: 10, 11, 15 — conflicts between devices

    func testConcurrentEditsResolveToTheNewestAndWritesConverge() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let id = UUID()
        try deliver(foods: [food("牛奶", in: fridge, updated: 800_000_000, id: id, quantity: 2),
                            food("牛奶", in: fridge, updated: 800_000_500, id: id, quantity: 5)], into: container)
        let store = SwiftDataFoodStore(container: container)
        XCTAssertEqual(try store.activeItems(fridgeID: fridge.id).map(\.quantity), [5], "newest change wins, shown once")
        var item = try XCTUnwrap(try store.activeItems(fridgeID: fridge.id).first)
        item.quantity = 1
        item.updatedAt = Date(timeIntervalSinceReferenceDate: 800_001_000)
        try store.upsert(item)
        let rows = try ModelContext(container).fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(rows.map(\.quantityText), ["1", "1"], "every copy updated")
    }

    func testConsumedOnAnotherDeviceMovesToHistory() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let id = UUID()
        try deliver(foods: [food("優格", in: fridge, updated: 800_000_000, id: id)], into: container)
        try deliver(foods: [food("優格", in: fridge, updated: 800_000_900, id: id, consumed: Date(timeIntervalSinceReferenceDate: 800_000_900))],
                    into: container)
        let store = SwiftDataFoodStore(container: container)
        XCTAssertTrue(try store.activeItems(fridgeID: fridge.id).isEmpty)
        XCTAssertEqual(try store.consumedItems(fridgeID: fridge.id).map(\.id), [id])
    }

    func testDeletionRemovesEveryCopyAndOrphansAreNeverReassigned() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let id = UUID()
        try deliver(foods: [food("牛奶", in: fridge, id: id), food("牛奶", in: fridge, id: id)], into: container)
        try SwiftDataFoodStore(container: container).delete(id: id)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<FoodItemRecord>()), 0)
        // An edit for food in a fridge deleted on another device arrives: kept, reported, not placed anywhere.
        let gone = FridgeFactory.makeDefault(name: "已刪除")
        let late = food("雞蛋", in: gone)
        try deliver(foods: [late], into: container)
        XCTAssertEqual(try SyncReconciler(container: container).run().unplacedFoodCount, 1)
        let session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(try session.directory.unplacedItems().map(\.id), [late.id])
        XCTAssertTrue(try session.foodStore.activeItems(fridgeID: fridge.id).isEmpty, "not silently assigned")
        try session.directory.placeUnplacedItems(into: fridge.id, compartmentID: fridge.cabinetCompartments[2].id)
        XCTAssertEqual(try session.foodStore.activeItems(fridgeID: fridge.id).first?.compartmentID, fridge.cabinetCompartments[2].id)
        XCTAssertTrue(try session.directory.unplacedItems().isEmpty)
    }

    // MARK: 12 — missing compartment

    func testFoodForAMissingCompartmentIsFlaggedNotMoved() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        var item = food("蘋果", in: fridge)
        item.compartmentID = UUID() // the compartment was removed on another device
        try deliver(foods: [item], into: container)
        let inventory = FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                                             compartments: { fridge.allCompartments })
        XCTAssertTrue(inventory.reload())
        XCTAssertEqual(inventory.itemsWithMissingCompartment.map(\.id), [item.id])
        XCTAssertEqual(try SwiftDataFoodStore(container: container).activeItems(fridgeID: fridge.id).first?.compartmentID, item.compartmentID)
    }

    // MARK: 13, 14 — accounts (policy A)

    func testAccountTransitions() {
        XCTAssertEqual(CloudAccountTransition.evaluate(stored: nil, current: "a", state: .available), .firstAccount("a"))
        XCTAssertEqual(CloudAccountTransition.evaluate(stored: "a", current: "a", state: .available), .sameAccount)
        XCTAssertEqual(CloudAccountTransition.evaluate(stored: "a", current: "b", state: .available), .accountChanged("b"))
        XCTAssertEqual(CloudAccountTransition.evaluate(stored: "a", current: nil, state: .noAccount), .unavailable)
        XCTAssertEqual(CloudAccountTransition.evaluate(stored: "a", current: "a", state: .temporarilyUnavailable), .unavailable)
        let monitor = CloudSyncMonitor(center: NotificationCenter())
        for state in [CloudAccountState.noAccount, .restricted, .temporarilyUnavailable, .unknown] {
            monitor.updateAccount(state)
            XCTAssertEqual(monitor.status(enabled: true), .unavailable(state))
            XCTAssertNotNil(monitor.status(enabled: true).detail)
        }
        XCTAssertEqual(monitor.status(enabled: false), .off)
    }

    func testAccountChangeKeepsThePreviousAccountsSnapshotAndAsksNothingSilently() throws {
        let settings = settings()
        settings.accountFingerprint = "aaaa"
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        try SwiftDataFoodStore(container: container).upsert(food("A 的牛奶", in: fridge))
        let service = backupService(container)
        snapshots.refresh(using: service, settings: settings, account: "aaaa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshots.url(for: .account("aaaa")).path))

        var noticeShown = 0
        let coordinator = CloudSyncCoordinator(settings: settings, monitor: CloudSyncMonitor(center: NotificationCenter()),
                                               snapshots: snapshots, account: FakeAccountProvider(state: .available, fingerprint: "bbbb"))
        coordinator.presentAccountNotice = { noticeShown += 1 }
        coordinator.apply(.accountChanged("bbbb"))
        XCTAssertEqual(settings.accountFingerprint, "bbbb")
        XCTAssertTrue(settings.hasPendingAccountNotice)
        XCTAssertEqual(noticeShown, 1)
        // iOS replaces the data with account B's (simulated: empty). Account A's copy is untouched.
        for item in try SwiftDataFoodStore(container: container).activeItems(fridgeID: fridge.id) {
            try SwiftDataFoodStore(container: container).delete(id: item.id)
        }
        snapshots.refresh(using: service, settings: settings, account: "bbbb")
        let a = try BackupValidator.decode(Data(contentsOf: snapshots.url(for: .account("aaaa"))))
        XCTAssertEqual(a.foods.map(\.name), ["A 的牛奶"], "restorable explicitly")
        XCTAssertTrue(try BackupValidator.decode(Data(contentsOf: snapshots.url(for: .account("bbbb")))).foods.isEmpty)
        XCTAssertEqual(Set(snapshots.list().map(\.kind)), [.account("aaaa"), .account("bbbb")])
    }

    // MARK: 16 — preferences

    func testFavoritesSyncThroughKeyValueStorage() throws {
        let kvs = FakeKeyValueStore()
        let favorites = UserDefaultsFavoriteFoodStore(defaults: defaults)
        var mine = FavoriteFoods()
        try mine.pin(FoodTemplate(name: "豆腐", categoryID: FoodCategoryCatalog.otherID, unit: "盒", preferredCompartmentID: nil))
        favorites.save(mine)
        let center = NotificationCenter()
        let sync = PreferenceCloudSync(cloud: kvs, defaults: defaults)
        sync.start(center: center)
        defer { sync.stop() }
        XCTAssertNotNil(kvs.values[UserDefaultsFavoriteFoodStore.key], "first device uploads its favorites")
        // Local change → uploaded.
        UserDefaultsFavoriteCategoryStore(defaults: defaults).save(FavoriteCategories(ids: ["fruits"]))
        XCTAssertEqual(kvs.values[UserDefaultsFavoriteCategoryStore.key] as? [String], ["fruits"])
        // Change from another device → applied locally.
        var theirs = FavoriteFoods()
        try theirs.pin(FoodTemplate(name: "吐司", categoryID: FoodCategoryCatalog.otherID, unit: "條", preferredCompartmentID: nil))
        kvs.values[UserDefaultsFavoriteFoodStore.key] = try JSONEncoder().encode(theirs.templates)
        let applied = expectation(forNotification: .favoritesDidChangeExternally, object: nil)
        center.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs,
                    userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [UserDefaultsFavoriteFoodStore.key]])
        wait(for: [applied], timeout: 2)
        XCTAssertEqual(favorites.load().templates.map(\.name), ["吐司"])
        XCTAssertNil(NotificationPreferences.self == NotificationPreferences.self ? kvs.values[UserDefaultsNotificationPreferencesStore.key] : nil,
                     "notification settings stay on the device")
    }

    /// Goes through the real NSUbiquitousKeyValueStore type (a recursive conformance once crashed at launch).
    func testRealKeyValueStoreConformance() {
        let store: KeyValueCloudStore = NSUbiquitousKeyValueStore()
        let key = "test-\(UUID().uuidString)"
        store.set(["a", "b"], forKey: key)
        XCTAssertEqual(store.object(forKey: key) as? [String], ["a", "b"])
        store.set(nil, forKey: key)
        XCTAssertNil(store.object(forKey: key))
        _ = store.synchronize()
    }

    func testSecondDeviceTakesFavoritesAlreadyInICloud() {
        let kvs = FakeKeyValueStore()
        kvs.values[UserDefaultsFavoriteCategoryStore.key] = ["meat"]
        defaults.set(["fruits"], forKey: UserDefaultsFavoriteCategoryStore.key)
        let sync = PreferenceCloudSync(cloud: kvs, defaults: defaults)
        sync.start(center: NotificationCenter())
        defer { sync.stop() }
        XCTAssertEqual(UserDefaultsFavoriteCategoryStore(defaults: defaults).load().ids, ["meat"])
    }

    // MARK: 17–21 — magnets and photos

    func testMagnetMetadataFromAnotherDeviceIsShownInOrder() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        func magnet(_ z: Int, _ id: UUID = UUID(), rotation: Double = 0, updated: TimeInterval = 800_000_000) -> FridgeMagnet {
            FridgeMagnet(id: id, fridgeID: fridge.id, source: .builtIn, builtInAssetID: "daisy", localImageID: nil,
                         centerX: 0.3, centerY: 0.6, width: 0.25, height: 0.2, rotation: rotation, zIndex: z,
                         createdAt: .now, updatedAt: Date(timeIntervalSinceReferenceDate: updated), style: .stamp)
        }
        let top = magnet(1), shared = UUID()
        try deliver(magnets: [top, magnet(0, shared, rotation: 0.1), magnet(0, shared, rotation: 0.7, updated: 800_000_100)], into: container)
        let library = MagnetLibrary(store: SwiftDataMagnetStore(container: container), images: MagnetImageStore(directory: work))
        let shown = try library.magnets(fridgeID: fridge.id)
        XCTAssertEqual(shown.map(\.id), [shared, top.id])
        XCTAssertEqual(shown[0].rotation, 0.7, accuracy: 1e-9, "newer move wins")
        XCTAssertEqual(shown[0].style, .stamp)
    }

    func testPhotoBytesTravelWithTheRecordAndArriveLate() throws {
        // Device A saves a photo magnet: the bytes go into a synced record.
        let deviceA = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: deviceA).loadAll()[0].fridge
        let imagesA = MagnetImageStore(directory: work.appendingPathComponent("A"))
        let photo = try imagesA.importImage(data: pngData())
        let libraryA = MagnetLibrary(store: SwiftDataMagnetStore(container: deviceA), images: imagesA)
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = try XCTUnwrap(draft.add(source: .photo, localImageID: photo.id, size: (0.4, 0.2)))
        _ = draft.duplicate(magnet.id)
        try libraryA.commit(draft)
        let bytes = try XCTUnwrap(try SwiftDataMagnetStore(container: deviceA).imageData(id: photo.id))
        XCTAssertEqual(bytes, imagesA.data(photo.id), "display-size bytes, uploaded once for both magnets")
        XCTAssertEqual(try ModelContext(deviceA).fetchCount(FetchDescriptor<MagnetImageRecord>()), 1)

        // Device B: the magnets arrive first → placeholder, position kept, nothing deleted.
        let deviceB = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let imagesB = MagnetImageStore(directory: work.appendingPathComponent("B"))
        let libraryB = MagnetLibrary(store: SwiftDataMagnetStore(container: deviceB), images: imagesB)
        try deliver(magnets: draft.magnets, into: deviceB)
        let arrived = try libraryB.magnets(fridgeID: fridge.id)
        XCTAssertEqual(arrived.map(\.id), draft.magnets.map(\.id))
        XCTAssertNil(libraryB.image(for: arrived[0]), "neutral placeholder until the photo arrives")
        let board = MagnetBoardView(template: .standardSingleDoor, library: libraryB)
        board.render(arrived)
        XCTAssertEqual(board.magnets.count, 2)
        // Editing on B before the photo arrives must not drop or "clean up" it.
        var editB = MagnetDraft(fridgeID: fridge.id, magnets: arrived)
        editB.move(arrived[0].id, dx: 0.1, dy: 0)
        try libraryB.commit(editB)
        XCTAssertEqual(try libraryB.magnets(fridgeID: fridge.id).count, 2)
        // The photo arrives later.
        try deliver(images: [photo.id: bytes], into: deviceB)
        let image = try XCTUnwrap(libraryB.image(for: arrived[0]))
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.01)
        XCTAssertEqual(imagesB.data(photo.id), bytes, "cached locally with identical bytes")
    }

    func testPhotoRecordsAreOnlyDeletedWhenNothingUsesThem() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let directory = try FridgeDirectory(fridgeStore: SwiftDataFridgeStore(container: container),
                                            foodStore: SwiftDataFoodStore(container: container), selection: InMemoryFridgeSelectionStore())
        let first = directory.fridges[0]
        let second = try directory.create(name: "儲藏室")
        let images = MagnetImageStore(directory: work)
        let library = MagnetLibrary(store: SwiftDataMagnetStore(container: container), images: images)
        let store = SwiftDataMagnetStore(container: container)
        // An image that arrived before its magnets is never touched by cleanup.
        let early = UUID()
        try deliver(images: [early: pngData()], into: container)
        let photo = try images.importImage(data: pngData())
        var a = MagnetDraft(fridgeID: first.id, magnets: [])
        a.add(source: .photo, localImageID: photo.id, size: (0.3, 0.3))
        try library.commit(a)
        var b = MagnetDraft(fridgeID: second.id, magnets: [])
        b.add(source: .photo, localImageID: photo.id, size: (0.3, 0.3))
        try library.commit(b)
        // Removing it from fridge 1: still used by fridge 2.
        var clearA = MagnetDraft(fridgeID: first.id, magnets: try library.magnets(fridgeID: first.id))
        clearA.delete(clearA.magnets[0].id)
        try library.commit(clearA)
        XCTAssertEqual(try store.storedImageIDs(), [early, photo.id])
        // Deleting fridge 2 (with its magnet) removes the last use.
        directory.onFridgeDeleted = { library.removeUnreferencedImages() }
        try directory.delete(second.id)
        XCTAssertEqual(try store.storedImageIDs(), [early], "the early photo stays for its magnets still on the way")
    }

    // MARK: 22, 23 — reminders and widgets after an import

    @MainActor
    func testImportedChangesRefreshScreensRemindersAndWidgets() async throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let selection = InMemoryFridgeSelectionStore()
        var session = try AppBootstrap.makeSession(container: container, mode: .persistent, selection: selection).get()
        let fridge = session.loadResult.fridge
        var refreshed = 0
        let coordinator = CloudSyncCoordinator(settings: settings(), monitor: CloudSyncMonitor(center: NotificationCenter()),
                                               snapshots: ProtectionSnapshots(directory: work), account: FakeAccountProvider(state: .noAccount))
        coordinator.currentSession = { session }
        coordinator.canRefresh = { true }
        coordinator.refresh = { _ in
            refreshed += 1
            session = try! AppBootstrap.makeSession(container: container, mode: .persistent, selection: selection).get()
        }
        coordinator.didOpen(cloudActive: false, problem: nil)
        defer { coordinator.stop() }
        coordinator.checkImportedData()
        XCTAssertEqual(refreshed, 0, "nothing changed → no rebuild")
        // Another device added food that expires tomorrow.
        var item = food("鮮奶", in: fridge)
        item.expirationDate = Date().addingTimeInterval(86_400)
        try deliver(foods: [item], into: container)
        coordinator.checkImportedData()
        XCTAssertEqual(refreshed, 1)
        coordinator.checkImportedData()
        XCTAssertEqual(refreshed, 1, "the same import is not applied twice")

        // The rebuilt home schedules the reminder (once) and writes the widget snapshot.
        let client = FakeNotificationClient()
        let file = WidgetSnapshotFile(url: work.appendingPathComponent("widget.json"))
        let publisher = WidgetSnapshotPublisher(file: file, reloader: CountingReloader())
        let home = FridgeHomeViewController(session: session, notificationClient: client, widgetPublisher: publisher)
        home.loadViewIfNeeded()
        _ = await home.syncAfterRestore()
        _ = await home.syncAfterRestore()
        XCTAssertEqual(client.pending.values.filter { $0.foodID == item.id }.count, 1, "no duplicate notification")
        publisher.waitUntilIdle()
        XCTAssertEqual(file.read()?.fridges.first?.refrigeratorID, fridge.id)
    }

    func testOnlyTheRealStoreUsesTheRealPhotoFolder() throws {
        let memory = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let file = try SwiftDataFridgeStore.makeContainer(url: work.appendingPathComponent("other.store"))
        XCTAssertNotEqual(MagnetImageStore.directory(for: memory), MagnetImageStore.defaultDirectory)
        XCTAssertNotEqual(MagnetImageStore.directory(for: file), MagnetImageStore.defaultDirectory)
        XCTAssertNotEqual(MagnetImageStore.directory(for: memory),
                          MagnetImageStore.directory(for: try SwiftDataFridgeStore.makeContainer(inMemory: true)))
        // A session on a test database cleaning up after a merge never touches the user's photo folder.
        let canary = MagnetImageStore.defaultDirectory.appendingPathComponent("canary-\(UUID().uuidString).img")
        try FileManager.default.createDirectory(at: MagnetImageStore.defaultDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }
        let session = try AppBootstrap.makeSession(container: memory, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        session.magnets.removeUnreferencedImages()
        session.directory.onFridgeDeleted?()
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path))
    }

    // MARK: 6 — schema

    func testSchemaIsCloudKitCompatible() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        for entity in container.schema.entities {
            for attribute in entity.attributes {
                XCTAssertFalse(attribute.isUnique, "\(entity.name).\(attribute.name) must not be unique")
                XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil, "\(entity.name).\(attribute.name) needs a default")
            }
            XCTAssertTrue(entity.relationships.isEmpty, "\(entity.name): no relationships (IDs only)")
        }
        XCTAssertEqual(Set(container.schema.entities.map(\.name)), ["FridgeRecord", "FoodItemRecord", "MagnetRecord", "MagnetImageRecord"])
        XCTAssertTrue(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil }, "tests never sync")
    }

    // MARK: Manual backup regressions

    func testManualBackupIsIndependentOfICloudAndPortable() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        try SwiftDataFoodStore(container: container).upsert(food("牛奶", in: fridge))
        let service = BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                                    preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: InMemoryFridgeSelectionStore()),
                                    recoveryDirectory: nil, exportDirectory: work.appendingPathComponent("Export"), applicationVersion: "test")
        let settings = settings()
        let monitor = CloudSyncMonitor(center: NotificationCenter())
        for enabled in [true, false] {
            settings.isEnabled = enabled
            monitor.updateAccount(enabled ? .available : .noAccount)
            monitor.handle(.init(id: UUID(), kind: .exporting, ended: .now, succeeded: false))
            let url = try service.exportFile()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "export works with sync \(enabled ? "on" : "off") and failing")
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for leaked in ["cloudkit", "recordname", "fingerprint", "icloud", "account", "transaction"] {
                XCTAssertFalse(text.contains(leaked), "no \(leaked) in a shared file")
            }
            // Another person (other Apple Account, fresh install) imports it.
            let theirContainer = try SwiftDataFridgeStore.makeContainer(inMemory: true)
            let theirSuite = "their-\(UUID().uuidString)"
            let theirDefaults = UserDefaults(suiteName: theirSuite)!
            defer { theirDefaults.removePersistentDomain(forName: theirSuite) }
            let theirs = BackupService(inventory: SwiftDataInventoryBackupStore(container: theirContainer),
                                       preferences: UserDefaultsPreferencesBackupStore(defaults: theirDefaults, selection: InMemoryFridgeSelectionStore()),
                                       recoveryDirectory: nil, applicationVersion: "test")
            try theirs.restore(try BackupService.readBackup(at: url))
            XCTAssertEqual(try SwiftDataFoodStore(container: theirContainer).activeItems(fridgeID: fridge.id).map(\.name), ["牛奶"])
            service.cleanUpExports()
        }
    }

    func testOldBackupsStillImport() throws {
        // The real Phase 4.3 export (format 2) and a format-1 file both import.
        let v2 = try BackupValidator.decode(Data(contentsOf: fixture("precloud-4.3-expected", "json")))
        XCTAssertEqual(v2.formatVersion, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture("precloud-4.3-expected", "json"))) as? [String: Any])
        json["formatVersion"] = 1
        json["magnets"] = nil
        json["magnetImages"] = nil
        let v1 = try BackupValidator.decode(JSONSerialization.data(withJSONObject: json))
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        try backupService(container).restore(v1)
        XCTAssertEqual(try SwiftDataFridgeStore(container: container).loadAll().map(\.fridge.id), v1.fridges.map(\.id))
    }

    func testRestoreUpdatesDuplicateRowsInsteadOfAddingMore() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let id = UUID()
        try deliver(foods: [food("牛奶", in: fridge, id: id, quantity: 1), food("牛奶", in: fridge, id: id, quantity: 2)], into: container)
        let images = MagnetImageStore(directory: work)
        let service = backupService(container, images: images)
        var backup = try service.makeBackup()
        backup.foods[0].quantity = "7"
        try service.restore(backup)
        try service.restore(backup)
        let rows = try ModelContext(container).fetch(FetchDescriptor<FoodItemRecord>())
        XCTAssertEqual(rows.count, 2, "no new rows: existing copies updated in place")
        XCTAssertEqual(Set(rows.map(\.quantityText)), ["7"])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<FridgeRecord>()), 1)
    }

    func testRestoredPhotosBecomeSyncedRecords() throws {
        let source = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: source).loadAll()[0].fridge
        let sourceImages = MagnetImageStore(directory: work.appendingPathComponent("src"))
        let library = MagnetLibrary(store: SwiftDataMagnetStore(container: source), images: sourceImages)
        let photo = try sourceImages.importImage(data: pngData())
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        draft.add(source: .photo, localImageID: photo.id, size: (0.3, 0.3))
        try library.commit(draft)
        let backup = try BackupValidator.decode(BackupCoding.encoder().encode(backupService(source, images: sourceImages).makeBackup()))
        let target = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        try backupService(target, images: MagnetImageStore(directory: work.appendingPathComponent("dst"))).restore(backup)
        XCTAssertEqual(try SwiftDataMagnetStore(container: target).imageData(id: photo.id), sourceImages.data(photo.id),
                       "the restored photo will sync to the recipient's other devices")
    }
}
