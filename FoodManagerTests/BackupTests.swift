import SwiftData
import UIKit
import XCTest
@testable import FoodManager

/// Inventory store wrapper with injectable failures.
final class FlakyInventoryBackupStore: InventoryBackupStore {
    struct Failure: Error {}
    let base: InventoryBackupStore
    /// Fails the next N replace calls.
    var failReplaces = 0
    /// Fails reads once N more successful reads happened (nil = never).
    var failReadAfter: Int?
    /// Replaces after this many succeed are "committed" with the last food dropped (simulates a bad write).
    var corruptNextReplace = false
    private(set) var replaceCount = 0

    init(base: InventoryBackupStore) { self.base = base }

    func readInventory() throws -> StoredInventory {
        if let remaining = failReadAfter {
            if remaining == 0 { failReadAfter = nil; throw Failure() }
            failReadAfter = remaining - 1
        }
        return try base.readInventory()
    }

    func replaceInventory(_ inventory: StoredInventory) throws {
        replaceCount += 1
        if failReplaces > 0 { failReplaces -= 1; throw Failure() }
        if corruptNextReplace {
            corruptNextReplace = false
            var corrupted = inventory
            corrupted.foods = Array(inventory.foods.dropLast())
            try base.replaceInventory(corrupted)
            return
        }
        try base.replaceInventory(inventory)
    }
}

final class FlakyPreferencesBackupStore: PreferencesBackupStore {
    struct Failure: Error {}
    let base: PreferencesBackupStore
    var failWrites = 0
    init(base: PreferencesBackupStore) { self.base = base }
    func readPreferences() -> BackupPreferences { base.readPreferences() }
    func writePreferences(_ preferences: BackupPreferences) throws {
        if failWrites > 0 { failWrites -= 1; throw Failure() }
        try base.writePreferences(preferences)
    }
}

/// Phase 4.2: backup format, validation, export, import and safe full-replacement restore.
final class BackupTests: XCTestCase {
    private var container: ModelContainer!
    private var foodStore: SwiftDataFoodStore!
    private var selection: InMemoryFridgeSelectionStore!
    private var directory: FridgeDirectory!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var workDirectory: URL!
    private var inventory: FlakyInventoryBackupStore!
    private var preferences: FlakyPreferencesBackupStore!
    private var service: BackupService!

    override func setUpWithError() throws {
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        foodStore = SwiftDataFoodStore(container: container)
        selection = InMemoryFridgeSelectionStore()
        directory = try FridgeDirectory(fridgeStore: SwiftDataFridgeStore(container: container), foodStore: foodStore, selection: selection)
        suiteName = "BackupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        service = makeService(container: container, selection: selection)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeService(container: ModelContainer, selection: FridgeSelectionStore) -> BackupService {
        inventory = FlakyInventoryBackupStore(base: SwiftDataInventoryBackupStore(container: container))
        preferences = FlakyPreferencesBackupStore(base: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection))
        return BackupService(inventory: inventory, preferences: preferences,
                             recoveryDirectory: workDirectory.appendingPathComponent("Recovery"),
                             exportDirectory: workDirectory.appendingPathComponent("Export"),
                             applicationVersion: "test")
    }

    private var first: Fridge { directory.fridges[0] }

    private func inventoryService(for fridge: Fridge) -> FoodInventoryService {
        FoodInventoryService(store: foodStore, fridgeID: fridge.id, compartments: { [unowned self] in
            self.directory.fridge(id: fridge.id)?.allCompartments ?? []
        })
    }

    @discardableResult
    private func addFood(_ name: String, to fridge: Fridge, compartment index: Int = 0, quantity: Decimal = 1,
                         category: String = FoodCategoryCatalog.otherID, expiresIn days: Int? = nil) throws -> FoodItem {
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[index].id)
        draft.name = name
        draft.quantity = quantity
        draft.categoryID = category
        draft.expirationDate = days.map { Date().addingTimeInterval(Double($0) * 86_400) }
        return try inventoryService(for: fridge).add(draft)
    }

    /// Two fridges, active food in both, one consumed record, favourites and notification settings.
    @discardableResult
    private func seedTwoFridges() throws -> (first: Fridge, second: Fridge, consumed: FoodItem) {
        let second = try directory.create(name: "儲藏室")
        try addFood("牛奶", to: first, quantity: Decimal(string: "1.5")!, expiresIn: 2)
        try addFood("雞蛋", to: first, compartment: 1, quantity: 10)
        try addFood("冷凍水餃", to: second, compartment: 0)
        let eaten = try addFood("優格", to: first)
        try inventoryService(for: first).markConsumed(eaten.id)
        try directory.select(second.id)
        defaults.set(["leafy-greens", "fruits"], forKey: UserDefaultsFavoriteCategoryStore.key)
        var favorites = FavoriteFoods()
        try favorites.pin(FoodTemplate(name: "豆腐", categoryID: FoodCategoryCatalog.otherID, unit: "盒", preferredCompartmentID: nil))
        try favorites.pin(FoodTemplate(name: "吐司", categoryID: FoodCategoryCatalog.otherID, unit: "條", preferredCompartmentID: nil))
        UserDefaultsFavoriteFoodStore(defaults: defaults).save(favorites)
        var notifications = NotificationPreferences()
        notifications.reminderHour = 20
        notifications.reminderMinute = 30
        notifications.expirationLeadDays = 3
        notifications.storageRemindersEnabled = false
        UserDefaultsNotificationPreferencesStore(defaults: defaults).save(notifications)
        return (first, second, try XCTUnwrap(foodStore.consumedItems(fridgeID: first.id).first))
    }

    private func encode(_ backup: FoodManagerBackup) throws -> Data { try BackupCoding.encoder().encode(backup) }

    private func jsonObject(_ backup: FoodManagerBackup) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encode(backup)) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func allFood() throws -> [FoodItem] {
        try directory.fridges.flatMap { try foodStore.activeItems(fridgeID: $0.id) + foodStore.consumedItems(fridgeID: $0.id) }
    }

    private func storedContent() throws -> FoodManagerBackup { try service.makeBackup() }

    // 1
    func testSerializationIsVersionedReadableJSON() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        let json = try jsonObject(backup)
        XCTAssertEqual(json["formatVersion"] as? Int, FoodManagerBackup.currentFormatVersion)
        XCTAssertEqual(json["applicationVersion"] as? String, "test")
        XCTAssertNotNil(json["backupID"])
        XCTAssertNotNil(json["exportedAt"])
        XCTAssertEqual((json["fridges"] as? [Any])?.count, 2)
        let text = try XCTUnwrap(String(data: encode(backup), encoding: .utf8))
        XCTAssertTrue(text.contains("牛奶"), "plain readable JSON, not encrypted")
        XCTAssertTrue(text.contains("\"quantity\" : \"1.5\""), "decimal kept as exact text")
        for excluded in ["premium", "transaction", "advert", "widget", "dev."] {
            XCTAssertFalse(text.lowercased().contains(excluded), "\(excluded) must not be in a backup")
        }
    }

    // 2
    func testDeserializationReturnsTheSameBackup() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        XCTAssertEqual(try BackupValidator.decode(encode(backup)), backup)
    }

    // 3, 17
    func testVersionValidation() throws {
        try seedTwoFridges()
        var json = try jsonObject(service.makeBackup())
        json["formatVersion"] = nil
        XCTAssertThrowsError(try BackupValidator.decode(data(json))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        json["formatVersion"] = 0
        XCTAssertThrowsError(try BackupValidator.decode(data(json))) { XCTAssertEqual($0 as? BackupError, .unsupportedVersion(0)) }
        // A future format is reported as such even if its fields changed shape.
        let future = try data(["formatVersion": 3, "somethingNew": true])
        XCTAssertThrowsError(try BackupValidator.decode(future)) {
            XCTAssertEqual($0 as? BackupError, .unsupportedVersion(3))
            XCTAssertTrue(($0 as? BackupError)?.message.contains("更新") == true)
        }
        XCTAssertThrowsError(try BackupValidator.decode(data(["fridges": []]))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
    }

    // 4
    func testOneFridgeBackup() throws {
        try addFood("牛奶", to: first)
        let backup = try service.makeBackup()
        XCTAssertEqual(backup.fridges.map(\.id), [first.id])
        XCTAssertEqual(backup.foods.count, 1)
        XCTAssertNoThrow(try BackupValidator.decode(encode(backup)))
    }

    // 5
    func testTwoFridgeBackupKeepsLayoutsAndOrder() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        XCTAssertEqual(backup.fridges.map(\.id), [seeded.first.id, seeded.second.id])
        XCTAssertEqual(backup.fridges.map(\.fridge), [seeded.first, directory.fridge(id: seeded.second.id)!])
        XCTAssertEqual(BackupValidator.summary(of: backup).fridgeNames, [FridgePolicy.defaultName, "儲藏室"])
    }

    // 6
    func testThreeFridgeBackupIsRejectedWithoutDroppingAnything() throws {
        try seedTwoFridges()
        let before = try storedContent()
        var backup = before
        var third = backup.fridges[1]
        third.id = UUID()
        third.name = "第三台"
        third.cabinetCompartments = third.cabinetCompartments.map { var c = $0; c.id = UUID(); return c }
        third.doorCompartments = third.doorCompartments.map { var c = $0; c.id = UUID(); return c }
        backup.fridges.append(third)
        XCTAssertThrowsError(try BackupValidator.decode(encode(backup))) {
            XCTAssertEqual($0 as? BackupError, .tooManyFridges(3))
            XCTAssertTrue(($0 as? BackupError)?.message.contains("不會自動刪除") == true)
        }
        XCTAssertThrowsError(try service.restore(backup))
        XCTAssertTrue(try storedContent().hasSameContent(as: before), "nothing changed")
        XCTAssertEqual(inventory.replaceCount, 0)
    }

    // 7, 8
    func testActiveFoodAndHistoryAreRestoredExactly() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        let originalActive = try foodStore.activeItems(fridgeID: seeded.first.id)
        // Change everything, then restore.
        for item in try allFood() { try foodStore.delete(id: item.id) }
        try addFood("其他東西", to: first)
        try service.restore(backup)
        XCTAssertEqual(try foodStore.activeItems(fridgeID: seeded.first.id), originalActive)
        let history = try foodStore.consumedItems(fridgeID: seeded.first.id)
        XCTAssertEqual(history, [seeded.consumed])
        XCTAssertEqual(history.first?.consumedAt, seeded.consumed.consumedAt)
        XCTAssertEqual(originalActive.first { $0.name == "牛奶" }?.quantity, Decimal(string: "1.5"))
        XCTAssertFalse(try allFood().contains { $0.name == "其他東西" })
    }

    // 9
    func testCompartmentOwnershipIsValidated() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        let otherFridgeCompartment = try XCTUnwrap(directory.fridge(id: seeded.second.id)?.cabinetCompartments.first?.id)

        var crossed = backup
        let activeIndex = try XCTUnwrap(crossed.foods.firstIndex { $0.fridgeID == seeded.first.id && $0.consumedAt == nil })
        crossed.foods[activeIndex].compartmentID = otherFridgeCompartment
        XCTAssertThrowsError(try BackupValidator.validate(crossed)) {
            XCTAssertEqual($0 as? BackupError, .invalidCompartmentReference(crossed.foods[activeIndex].name))
        }

        var historyCrossed = backup
        let historyIndex = try XCTUnwrap(historyCrossed.foods.firstIndex { $0.consumedAt != nil })
        historyCrossed.foods[historyIndex].compartmentID = otherFridgeCompartment
        XCTAssertThrowsError(try BackupValidator.validate(historyCrossed), "history never points at another fridge")

        var historyOrphan = backup
        historyOrphan.foods[historyIndex].compartmentID = UUID()
        XCTAssertNoThrow(try BackupValidator.validate(historyOrphan), "history may outlive a deleted compartment")

        var unknownFridge = backup
        unknownFridge.foods[activeIndex].fridgeID = UUID()
        XCTAssertThrowsError(try BackupValidator.validate(unknownFridge))
    }

    // 10
    func testRefrigeratedAndFrozenClassificationIsPreserved() throws {
        var fridge = first
        fridge.cabinetCompartments[0].storageType = .frozen
        try SwiftDataFridgeStore(container: container).saveLayout(fridge)
        try directory.reload()
        let backup = try service.makeBackup()
        XCTAssertEqual(backup.fridges[0].cabinetCompartments[0].storageType, .frozen)
        // Change it back, then restore.
        fridge.cabinetCompartments[0].storageType = .refrigerated
        try SwiftDataFridgeStore(container: container).saveLayout(fridge)
        try service.restore(backup)
        let restored = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        XCTAssertEqual(restored.cabinetCompartments.map(\.storageType), backup.fridges[0].cabinetCompartments.map(\.storageType))
        XCTAssertEqual(restored.cabinetCompartments[0].storageType, .frozen)
        XCTAssertEqual(restored.doorCompartments.map(\.storageType), restored.doorCompartments.map { _ in .unspecified })
    }

    // 11, 12, 13
    func testPreferencesAreRestoredInOrder() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        XCTAssertEqual(backup.preferences.favoriteCategoryIDs, ["leafy-greens", "fruits"])
        XCTAssertEqual(backup.preferences.favoriteFoods.map(\.name), ["豆腐", "吐司"])
        defaults.set(["meat"], forKey: UserDefaultsFavoriteCategoryStore.key)
        UserDefaultsFavoriteFoodStore(defaults: defaults).save(FavoriteFoods())
        UserDefaultsNotificationPreferencesStore(defaults: defaults).save(NotificationPreferences())

        try service.restore(backup)
        XCTAssertEqual(UserDefaultsFavoriteCategoryStore(defaults: defaults).load().ids, ["leafy-greens", "fruits"])
        XCTAssertEqual(UserDefaultsFavoriteFoodStore(defaults: defaults).load().templates, backup.preferences.favoriteFoods)
        let notifications = UserDefaultsNotificationPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(notifications.reminderHour, 20)
        XCTAssertEqual(notifications.reminderMinute, 30)
        XCTAssertEqual(notifications.expirationLeadDays, 3)
        XCTAssertFalse(notifications.storageRemindersEnabled)
    }

    // 14
    func testDuplicateIDsAreRejected() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        var food = backup
        food.foods.append(food.foods[0])
        XCTAssertThrowsError(try BackupValidator.validate(food)) { XCTAssertEqual($0 as? BackupError, .duplicateIDs) }
        var compartment = backup
        compartment.fridges[1].cabinetCompartments[0].id = compartment.fridges[0].cabinetCompartments[0].id
        XCTAssertThrowsError(try BackupValidator.validate(compartment)) { XCTAssertEqual($0 as? BackupError, .duplicateIDs) }
        var fridge = backup
        fridge.fridges[1].id = fridge.fridges[0].id
        XCTAssertThrowsError(try BackupValidator.validate(fridge)) { XCTAssertEqual($0 as? BackupError, .duplicateIDs) }
        var favorite = backup
        favorite.preferences.favoriteFoods[1] = FavoriteFoodTemplate(id: favorite.preferences.favoriteFoods[0].id, name: "麵包",
                                                                     categoryID: FoodCategoryCatalog.otherID, unit: "個", preferredCompartmentID: nil)
        XCTAssertThrowsError(try BackupValidator.validate(favorite)) { XCTAssertEqual($0 as? BackupError, .duplicateIDs) }
    }

    // 15
    func testInvalidCompartmentAndFieldsAreRejected() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        let active = try XCTUnwrap(backup.foods.firstIndex { $0.consumedAt == nil })
        var missing = backup
        missing.foods[active].compartmentID = UUID()
        XCTAssertThrowsError(try BackupValidator.validate(missing)) {
            XCTAssertEqual($0 as? BackupError, .invalidCompartmentReference(missing.foods[active].name))
        }
        for change in [{ (f: inout BackupFood) in f.quantity = "-1" }, { $0.quantity = "abc" }, { $0.name = "  " },
                       { $0.storageReminderDays = 0 }, { $0.unit = "" },
                       { $0.storedAt = Date(timeIntervalSince1970: -10) }] {
            var bad = backup
            change(&bad.foods[active])
            XCTAssertThrowsError(try BackupValidator.validate(bad))
        }
        var layout = backup
        layout.fridges[0].cabinetCompartments[0].frame = NormalizedRect(x: 0, y: 0.5, width: 1, height: 2)
        XCTAssertThrowsError(try BackupValidator.validate(layout)) { XCTAssertEqual($0 as? BackupError, .invalidLayout(FridgePolicy.defaultName)) }
        var prefs = backup
        prefs.preferences.notifications.reminderHour = 25
        XCTAssertThrowsError(try BackupValidator.validate(prefs)) { XCTAssertEqual($0 as? BackupError, .invalidPreferences) }
        var empty = backup
        empty.fridges = []
        empty.foods = []
        XCTAssertThrowsError(try BackupValidator.validate(empty)) { XCTAssertEqual($0 as? BackupError, .noFridges) }
    }

    // 16
    func testMalformedJSONIsRejectedAndNothingChanges() throws {
        try seedTwoFridges()
        let before = try storedContent()
        let valid = try encode(before)
        for corrupt in [valid.prefix(valid.count / 2), Data("not json".utf8), Data(), Data("[1,2]".utf8)] {
            XCTAssertThrowsError(try BackupValidator.decode(Data(corrupt))) { XCTAssertEqual($0 as? BackupError, .malformed) }
        }
        var json = try jsonObject(before)
        json["fridges"] = "oops"
        XCTAssertThrowsError(try BackupValidator.decode(data(json))) { XCTAssertEqual($0 as? BackupError, .malformed) }
        XCTAssertTrue(try storedContent().hasSameContent(as: before))
        XCTAssertEqual(inventory.replaceCount, 0)
    }

    // 18
    func testOversizedFileIsRejectedBeforeReading() throws {
        try seedTwoFridges()
        let url = workDirectory.appendingPathComponent("big.json")
        try encode(service.makeBackup()).write(to: url)
        XCTAssertThrowsError(try BackupService.readBackup(at: url, maxFileSize: 100)) {
            guard case .fileTooLarge = $0 as? BackupError else { return XCTFail("\($0)") }
        }
        XCTAssertNoThrow(try BackupService.readBackup(at: url))
        var tooMany = try service.makeBackup()
        tooMany.foods = (0...BackupValidator.maxFoodRecords).map { _ in var f = tooMany.foods[0]; f.id = UUID(); return f }
        XCTAssertThrowsError(try BackupValidator.validate(tooMany)) { XCTAssertEqual($0 as? BackupError, .tooManyRecords) }
    }

    // 19
    func testCancelledOrMissingImportChangesNothing() throws {
        try seedTwoFridges()
        let before = try storedContent()
        var restoredCalls = 0
        let flow = BackupFlow(service: service) { _ in restoredCalls += 1 }
        flow.documentPickerWasCancelled(UIDocumentPickerViewController(forOpeningContentTypes: [.json]))
        XCTAssertThrowsError(try BackupService.readBackup(at: workDirectory.appendingPathComponent("missing.json"))) {
            XCTAssertEqual($0 as? BackupError, .unreadable)
        }
        XCTAssertEqual(restoredCalls, 0)
        XCTAssertTrue(try storedContent().hasSameContent(as: before))
    }

    // 20
    func testDatabaseSaveFailureLeavesEverythingUnchanged() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        try addFood("新加的", to: first)
        let before = try storedContent()
        inventory.failReplaces = 1
        XCTAssertThrowsError(try service.restore(backup)) { XCTAssertEqual($0 as? BackupError, .saveFailed) }
        XCTAssertTrue(try storedContent().hasSameContent(as: before))
    }

    // 21
    func testRecoverySnapshotIsWrittenBeforeReplacing() throws {
        try seedTwoFridges()
        let before = try storedContent()
        var backup = before
        backup.foods.removeAll { $0.consumedAt == nil }
        try service.restore(backup)
        let url = try XCTUnwrap(service.recoveryFileURL)
        let snapshot = try BackupValidator.decode(Data(contentsOf: url))
        XCTAssertTrue(snapshot.hasSameContent(as: before), "the pre-restore copy holds the previous data")
        XCTAssertTrue(try storedContent().hasSameContent(as: BackupService.canonical(backup)))
    }

    func testRecoverySnapshotFailureStopsTheRestore() throws {
        try seedTwoFridges()
        let before = try storedContent()
        let blocker = workDirectory.appendingPathComponent("Blocked")
        try Data().write(to: blocker) // a file where the directory should be
        let blocked = BackupService(inventory: inventory, preferences: preferences, recoveryDirectory: blocker)
        var backup = before
        backup.foods = []
        XCTAssertThrowsError(try blocked.restore(backup)) { XCTAssertEqual($0 as? BackupError, .recoverySnapshotFailed) }
        XCTAssertEqual(inventory.replaceCount, 0)
        XCTAssertTrue(try storedContent().hasSameContent(as: before))
    }

    // 22, 23
    func testSuccessfulReplacementWithoutDuplicates() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        // Modify the configuration: rename, delete food, add food.
        try directory.rename(seeded.first.id, to: "改過的名字")
        try addFood("多出來的", to: first)
        try service.restore(backup)
        try service.restore(backup) // twice: still one copy of each record
        try directory.reload()
        XCTAssertEqual(directory.fridges.map(\.name), [FridgePolicy.defaultName, "儲藏室"])
        let ids = try allFood().map(\.id)
        XCTAssertEqual(ids.count, backup.foods.count)
        XCTAssertEqual(Set(ids), Set(backup.foods.map(\.id)))
        XCTAssertTrue(try storedContent().hasSameContent(as: backup))
    }

    // 24
    func testSelectedFridgeIsRestoredOrFallsBackToTheFirst() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        XCTAssertEqual(backup.preferences.selectedFridgeID, seeded.second.id)
        try directory.select(seeded.first.id)
        try service.restore(backup)
        XCTAssertEqual(selection.selectedFridgeID, seeded.second.id)
        XCTAssertEqual(try FridgeDirectory(fridgeStore: SwiftDataFridgeStore(container: container), foodStore: foodStore,
                                           selection: selection).selectedID, seeded.second.id)
        var stale = backup
        stale.preferences.selectedFridgeID = UUID()
        try service.restore(stale)
        XCTAssertEqual(selection.selectedFridgeID, seeded.first.id)
    }

    // 25
    @MainActor
    func testNotificationsAreRescheduledFromRestoredData() async throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        for item in try allFood() { try foodStore.delete(id: item.id) }
        let removed = try addFood("被取代", to: first, expiresIn: 1)
        let client = FakeNotificationClient()
        let session = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting, selection: selection).get()
        let coordinator = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(), snapshot: {
            let items = session.directory.fridges.flatMap { (try? session.foodStore.activeItems(fridgeID: $0.id)) ?? [] }
            return (items, session.directory.fridges.flatMap(\.allCompartments))
        })
        _ = await coordinator.reschedule()
        XCTAssertTrue(client.pending.values.contains { $0.foodID == removed.id })

        try service.restore(backup)
        let restored = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting, selection: selection).get()
        let after = NotificationCoordinator(client: client, preferencesStore: InMemoryPreferencesStore(), snapshot: {
            let items = restored.directory.fridges.flatMap { (try? restored.foodStore.activeItems(fridgeID: $0.id)) ?? [] }
            return (items, restored.directory.fridges.flatMap(\.allCompartments))
        })
        let ok = await after.syncNow()
        XCTAssertTrue(ok)
        XCTAssertFalse(client.pending.values.contains { $0.foodID == removed.id }, "replaced food has no reminders left")
        let milk = try XCTUnwrap(try foodStore.activeItems(fridgeID: seeded.first.id).first { $0.name == "牛奶" })
        XCTAssertTrue(client.pending.values.contains { $0.foodID == milk.id })
    }

    // 26
    func testWidgetSnapshotIsRegeneratedFromRestoredData() throws {
        let seeded = try seedTwoFridges()
        let backup = try service.makeBackup()
        for item in try allFood() { try foodStore.delete(id: item.id) }
        try service.restore(backup)
        let session = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting, selection: selection).get()
        let file = WidgetSnapshotFile(url: workDirectory.appendingPathComponent("widget.json"))
        let reloader = CountingReloader()
        let publisher = WidgetSnapshotPublisher(file: file, reloader: reloader)
        let items = try session.directory.fridges.flatMap { try session.foodStore.activeItems(fridgeID: $0.id) }
        let done = expectation(description: "published")
        publisher.publish(fridges: session.directory.fridges, items: items, selectedFridgeID: session.loadResult.fridge.id) {
            XCTAssertTrue($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let bundle = try XCTUnwrap(file.read())
        XCTAssertEqual(bundle.fridges.map(\.refrigeratorID), [seeded.first.id, seeded.second.id])
        XCTAssertEqual(bundle.selectedFridgeID, seeded.second.id)
        XCTAssertEqual(reloader.count, 1)
    }

    // 27
    func testRestoredDataSurvivesRelaunch() throws {
        let url = workDirectory.appendingPathComponent("store.sqlite")
        var backup: FoodManagerBackup!
        do {
            backup = try { () throws -> FoodManagerBackup in
                try seedTwoFridges()
                return try service.makeBackup()
            }()
        }
        do {
            let disk = try SwiftDataFridgeStore.makeContainer(url: url)
            let diskSelection = InMemoryFridgeSelectionStore()
            _ = try AppBootstrap.makeSession(container: disk, mode: .persistent, selection: diskSelection).get() // first launch: default fridge
            try makeService(container: disk, selection: diskSelection).restore(backup)
        }
        // "Relaunch": a new container on the same file.
        let relaunched = try SwiftDataFridgeStore.makeContainer(url: url)
        let session = try AppBootstrap.makeSession(container: relaunched, mode: .persistent, selection: InMemoryFridgeSelectionStore()).get()
        XCTAssertEqual(session.directory.fridges.map(\.id), backup.fridges.map(\.id))
        let stored = try SwiftDataInventoryBackupStore(container: relaunched).readInventory()
        XCTAssertEqual(stored.foods.sorted { $0.id.uuidString < $1.id.uuidString },
                       BackupService.canonical(backup).foods.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    // 28
    func testPreferencesFailureRollsBackTheDatabase() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        try addFood("還原前新增", to: first)
        defaults.set(["meat"], forKey: UserDefaultsFavoriteCategoryStore.key)
        let before = try storedContent()
        preferences.failWrites = 1
        XCTAssertThrowsError(try service.restore(backup)) { XCTAssertEqual($0 as? BackupError, .restoreFailed(rolledBack: true)) }
        XCTAssertTrue(try storedContent().hasSameContent(as: before), "database and preferences are back to the previous state")
        XCTAssertTrue(try allFood().contains { $0.name == "還原前新增" })
    }

    // 29
    func testFailureAfterDatabaseStagingRollsBack() throws {
        try seedTwoFridges()
        let backup = try service.makeBackup()
        try addFood("還原前新增", to: first)
        let before = try storedContent()

        // The write "succeeds" but the read-back doesn't match → rollback.
        inventory.corruptNextReplace = true
        XCTAssertThrowsError(try service.restore(backup)) { XCTAssertEqual($0 as? BackupError, .restoreFailed(rolledBack: true)) }
        XCTAssertTrue(try storedContent().hasSameContent(as: before))

        // The verification read itself fails → rollback.
        inventory.failReadAfter = 1 // snapshot read ok, verification read fails
        XCTAssertThrowsError(try service.restore(backup)) { XCTAssertEqual($0 as? BackupError, .restoreFailed(rolledBack: true)) }
        XCTAssertTrue(try storedContent().hasSameContent(as: before))

        // Even the rollback fails: reported honestly, and the recovery copy is on disk.
        preferences.failWrites = 2
        XCTAssertThrowsError(try service.restore(backup)) { XCTAssertEqual($0 as? BackupError, .restoreFailed(rolledBack: false)) }
        let snapshot = try BackupValidator.decode(Data(contentsOf: XCTUnwrap(service.recoveryFileURL)))
        XCTAssertTrue(snapshot.hasSameContent(as: before))
    }

    // 30
    func testFullRoundTripThroughAFile() throws {
        try seedTwoFridges()
        // A category ID from a newer build survives (shown as 其他).
        var future = try XCTUnwrap(try foodStore.activeItems(fridgeID: first.id).first)
        future.categoryID = "future-category"
        try foodStore.upsert(future)
        let original = try service.makeBackup()

        let url = try service.exportFile()
        XCTAssertEqual(url.lastPathComponent, BackupService.fileName(for: original.exportedAt))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("FoodManager-Backup-"))
        let imported = try BackupService.readBackup(at: url)
        service.cleanUpExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "temporary export is cleaned up")
        XCTAssertEqual(BackupValidator.summary(of: imported).unknownCategoryCount, 1)

        // Restore into a brand-new install.
        let fresh = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let freshSelection = InMemoryFridgeSelectionStore()
        defaults.removePersistentDomain(forName: suiteName)
        let freshService = makeService(container: fresh, selection: freshSelection)
        try freshService.restore(imported)
        let roundTripped = try freshService.makeBackup()
        XCTAssertTrue(roundTripped.hasSameContent(as: original))
        let restored = try XCTUnwrap(try SwiftDataFoodStore(container: fresh).activeItems(fridgeID: first.id).first { $0.id == future.id })
        XCTAssertEqual(restored.categoryID, "future-category")
        XCTAssertEqual(FoodCategoryCatalog.category(id: restored.categoryID).id, FoodCategoryCatalog.otherID)
    }

    func testExportFileNameUsesTheExportDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let date = Date(timeIntervalSince1970: 1_792_627_200) // 2026-10-22 08:00 Taipei
        XCTAssertEqual(BackupService.fileName(for: date, calendar: calendar), "FoodManager-Backup-2026-10-22.json")
    }

    @MainActor
    func testSettingsShowsDataManagementSection() {
        let coordinator = NotificationCoordinator(client: FakeNotificationClient(), preferencesStore: InMemoryPreferencesStore(), snapshot: { nil })
        let settings = SettingsViewController(entitlements: nil, ads: nil, notifications: coordinator,
                                              backup: BackupFlow(service: service) { _ in },
                                              icloudBackup: ICloudBackupService(store: LocalOnlyBackupTests.FakeBackupStore(),
                                                                                defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!))
        settings.loadViewIfNeeded()
        let titles = (0..<settings.numberOfSections(in: settings.tableView)).map { settings.tableView(settings.tableView, titleForHeaderInSection: $0) }
        func labels(_ title: String) -> [String] {
            guard let section = titles.firstIndex(of: title) else { return [] }
            return (0..<settings.tableView(settings.tableView, numberOfRowsInSection: section)).compactMap {
                (settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: $0, section: section)).contentConfiguration as? UIListContentConfiguration)?.text
            }
        }
        XCTAssertEqual(labels("iCloud 備份"), ["iCloud 備份"])
        XCTAssertEqual(labels("手動檔案備份"), ["匯出備份", "匯入備份"], "manual file backup stays available")
        let fileSection = titles.firstIndex(of: "手動檔案備份")
        XCTAssertTrue(fileSection.flatMap { settings.tableView(settings.tableView, titleForFooterInSection: $0) }?.contains("沒有加密") == true)
        let all = titles.indices.flatMap { section in (0..<settings.tableView(settings.tableView, numberOfRowsInSection: section)).compactMap {
            (settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: $0, section: section)).contentConfiguration as? UIListContentConfiguration)?.text
        } }
        XCTAssertFalse(all.contains { $0.contains("自動同步") }, "no automatic sync label anywhere")
    }
}
