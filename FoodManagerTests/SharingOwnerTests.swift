import CloudKit
import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5D-2: turning a personal fridge into a shared one, routing between the personal and shared stores, and
/// owner-only structure. CloudKit is replaced by a fake that "confirms" uploads the way the sync engine does; real
/// sharing still needs two devices with different iCloud accounts.
@MainActor
final class SharingOwnerTests: XCTestCase {
    private final class FakeCloud: SharingCloud {
        var isReady = true
        var failUpload = false
        var failShares = false
        var uploads: [UUID] = []
        var rollbacks: [UUID] = []
        weak var inventory: SharedInventory?

        func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {
            uploads.append(fridgeID)
            if failUpload { throw SharingServiceError.uploadIncomplete }
            // Server confirmation: the engine stores each saved record's system fields.
            for id in records {
                if let record = try inventory?.store.outgoingRecord(for: id, scope: .private) { try inventory?.store.didSave(record) }
            }
        }

        func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) {
            if failShares { throw SharingServiceError.shareFailed }
            return (URL(string: "https://www.icloud.com/share/inventory-\(fridgeID.uuidString)")!,
                    URL(string: "https://www.icloud.com/share/structure-\(fridgeID.uuidString)")!)
        }

        func rollback(fridgeID: UUID) { rollbacks.append(fridgeID) }
        var resets: [UUID] = []
        func resetZones(fridgeID: UUID) async throws { resets.append(fridgeID) }
    }

    private var defaults: UserDefaults!
    private var snapshotDirectory: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "SharingOwnerTests-\(UUID().uuidString)")
        snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SharingOwnerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    private let active = SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false, accessRequestsSupported: true)

    private struct Fixture {
        let container: ModelContainer
        let personal: SwiftDataFridgeStore
        let inventory: SharedInventory
        let cloud: FakeCloud
        let service: SharingService
        var changes: [SharedInventory.Change]
        let session: AppSession
    }

    private func makeFixture(policy: SharingPolicy? = nil) throws -> (Fixture, () -> [SharedInventory.Change]) {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let inventory = SharedInventory(store: SharedStore(container: try SharedStore.makeContainer(inMemory: true)))
        var changes: [SharedInventory.Change] = []
        inventory.onLocalChange = { changes.append($0) }
        let cloud = FakeCloud()
        cloud.inventory = inventory
        let personal = SwiftDataFridgeStore(container: container)
        let service = SharingService(policy: policy ?? active, inventory: inventory, cloud: cloud, personal: personal,
                                     hasPremium: { false }, snapshots: ProtectionSnapshots(directory: snapshotDirectory), defaults: defaults)
        guard case let .success(session) = AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting,
                                                                    selection: InMemoryFridgeSelectionStore(), sharing: service) else {
            throw XCTSkip("session")
        }
        return (Fixture(container: container, personal: personal, inventory: inventory, cloud: cloud, service: service,
                        changes: [], session: session), { changes })
    }

    private func addFood(_ name: String, quantity: Decimal, to fridge: Fridge, store: FoodStore) throws -> FoodItem {
        let now = Date()
        let item = FoodItem(id: UUID(), name: name, categoryID: "dairy", quantity: quantity, unit: "瓶", storedAt: now,
                            expirationDate: nil, storageReminderDays: nil, fridgeID: fridge.id,
                            compartmentID: fridge.cabinetCompartments[0].id, createdAt: now, updatedAt: now, consumedAt: nil)
        try store.upsert(item)
        return item
    }

    private func backups(_ session: AppSession) -> BackupService { session.makeBackupService(defaults: defaults) }

    // MARK: Conversion

    func testSharingMovesTheFridgeAndKeepsEverything() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        let milk = try addFood("牛奶", quantity: 5, to: fridge, store: fixture.session.foodStore)

        let url = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        XCTAssertTrue(url.absoluteString.contains("inventory"), "the invitation is the inventory share (access requests)")
        XCTAssertEqual(fixture.service.ownership(of: fridge.id), .sharedOwned)
        XCTAssertEqual(fixture.service.invitationURL(for: fridge.id), url)
        XCTAssertTrue(try fixture.personal.loadExisting().isEmpty, "personal copy removed only after confirmation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent(ProtectionSnapshots.beforeSharingFileName).path))

        // Still one fridge for the UI, same ID, same food — and no new default fridge.
        let routing = RoutingFridgeStore(personal: fixture.personal, shared: fixture.inventory)
        XCTAssertEqual(try routing.loadAll().map(\.fridge.id), [fridge.id])
        let food = RoutingFoodStore(personal: SwiftDataFoodStore(container: fixture.container), shared: fixture.inventory)
        XCTAssertEqual(try food.activeItems(fridgeID: fridge.id).map(\.id), [milk.id])
        XCTAssertEqual(try food.activeItems(fridgeID: fridge.id).first?.quantity, 5)
        XCTAssertEqual(defaults.stringArray(forKey: SharingService.pendingRemovalKey) ?? [], [])

        // Sharing again just returns the link.
        let again = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        XCTAssertEqual(again, url)
        XCTAssertEqual(fixture.cloud.uploads.count, 1)
    }

    func testFailedUploadLeavesThePersonalFridgeUntouched() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        _ = try addFood("蛋", quantity: 10, to: fridge, store: fixture.session.foodStore)
        fixture.cloud.failUpload = true
        do {
            _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .uploadIncomplete)
        }
        XCTAssertEqual(try fixture.personal.loadExisting().map(\.fridge.id), [fridge.id])
        XCTAssertEqual(try SwiftDataFoodStore(container: fixture.container).activeItems(fridgeID: fridge.id).count, 1)
        XCTAssertFalse(fixture.inventory.contains(fridge.id), "shared copy discarded")
        XCTAssertEqual(fixture.cloud.rollbacks, [fridge.id], "zones removed again")
    }

    func testFailedShareCreationRollsBack() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        fixture.cloud.failShares = true
        do {
            _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
            XCTFail("must fail")
        } catch {}
        XCTAssertEqual(try fixture.personal.loadExisting().map(\.fridge.id), [fridge.id])
        XCTAssertFalse(fixture.inventory.contains(fridge.id))
        XCTAssertEqual(fixture.cloud.rollbacks, [fridge.id])
    }

    func testGatesStopBeforeAnythingChanges() async throws {
        let off = SharingPolicy(sharedRefrigeratorsEnabled: false, sharedRefrigeratorsRequirePremium: false, accessRequestsSupported: true)
        let (disabled, _) = try makeFixture(policy: off)
        let fridge = disabled.session.loadResult.fridge
        XCTAssertFalse(disabled.service.canOfferSharing(fridge.id), "no entry point while off")
        do {
            _ = try await disabled.service.share(fridgeID: fridge.id, backups: backups(disabled.session))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .notAllowed(.disabled))
        }
        XCTAssertTrue(disabled.cloud.uploads.isEmpty)

        let premium = SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: true, accessRequestsSupported: true)
        let (paid, _) = try makeFixture(policy: premium)
        do {
            _ = try await paid.service.share(fridgeID: paid.session.loadResult.fridge.id, backups: backups(paid.session))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .notAllowed(.requiresPremium), "Premium is never faked")
        }

        let (offline, _) = try makeFixture()
        offline.cloud.isReady = false
        do {
            _ = try await offline.service.share(fridgeID: offline.session.loadResult.fridge.id, backups: backups(offline.session))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .syncUnavailable)
        }
        XCTAssertTrue(offline.cloud.uploads.isEmpty)
    }

    func testLeftoversOfAFailedAttemptDontHideThePersonalFridge() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        let milk = try addFood("牛奶", quantity: 5, to: fridge, store: fixture.session.foodStore)
        // A failed attempt: only the structure reached iCloud, then the sync engine fetched it back.
        let partial = SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                                  layoutData: try StoredLayout.encode(fridge), createdAt: .now, updatedAt: .now),
                                               ownerName: CKCurrentUserDefaultName, systemFields: nil)
        try fixture.inventory.store.apply(modifications: [partial, CKShare(recordZoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory))],
                                          deletions: [], scope: .private)

        // The personal fridge (with its food) is still what the app shows, and it can be shared again.
        XCTAssertEqual(fixture.service.incompleteConversions(), [fridge.id])
        XCTAssertEqual(fixture.service.ownership(of: fridge.id), .personalOwned)
        XCTAssertTrue(fixture.service.canOfferSharing(fridge.id))
        let food = RoutingFoodStore(personal: SwiftDataFoodStore(container: fixture.container), shared: fixture.inventory)
        XCTAssertEqual(try food.activeItems(fridgeID: fridge.id).map(\.id), [milk.id])
        XCTAssertTrue(FridgePolicy.canAddFridge(personal: 1, shared: []))
        XCTAssertTrue(fixture.service.backupExclusion().fridgeIDs.isEmpty, "its backup stays restorable")

        // Sharing again starts over: the leftover zones are reset first, then everything is uploaded.
        let url = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        XCTAssertTrue(url.absoluteString.contains("inventory"))
        XCTAssertEqual(fixture.cloud.resets, [fridge.id])
        XCTAssertEqual(fixture.service.ownership(of: fridge.id), .sharedOwned)
        XCTAssertTrue(fixture.service.incompleteConversions().isEmpty)
        XCTAssertEqual(try food.activeItems(fridgeID: fridge.id).first?.quantity, 5, "food made it into the shared fridge")
        XCTAssertTrue(try fixture.personal.loadExisting().isEmpty)
    }

    func testFailureNamesTheStepAndCloudKitCode() async throws {
        final class FailingCloud: SharingCloud {
            var isReady = true
            func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws { throw CKError(.invalidArguments) }
            func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) { throw SharingServiceError.shareFailed }
            func rollback(fridgeID: UUID) {}
            func resetZones(fridgeID: UUID) async throws {}
        }
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let inventory = SharedInventory(store: SharedStore(container: try SharedStore.makeContainer(inMemory: true)))
        let service = SharingService(policy: active, inventory: inventory, cloud: FailingCloud(), personal: SwiftDataFridgeStore(container: container),
                                     hasPremium: { false }, snapshots: nil, defaults: defaults)
        let session = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: service).get()
        do {
            _ = try await service.share(fridgeID: session.loadResult.fridge.id, backups: backups(session))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .cloudKit(step: "上傳", code: CKError.Code.invalidArguments.rawValue))
            XCTAssertTrue((error as? SharingServiceError)?.message.contains("CloudKit 錯誤 12") ?? false)
        }
        XCTAssertFalse(inventory.contains(session.loadResult.fridge.id))
    }

    func testInterruptedRemovalIsFinishedLater() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        // Simulate a personal copy that survived (e.g. the removal failed): hidden from the UI, removed on retry.
        try fixture.personal.create(fridge)
        defaults.set([fridge.id.uuidString], forKey: SharingService.pendingRemovalKey)
        let routing = RoutingFridgeStore(personal: fixture.personal, shared: fixture.inventory)
        XCTAssertEqual(try routing.loadAll().map(\.fridge.id), [fridge.id], "never shown twice")
        fixture.service.finishPendingRemovals()
        XCTAssertTrue(try fixture.personal.loadExisting().isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: SharingService.pendingRemovalKey) ?? [], [])
    }

    // MARK: Routing and roles

    func testOwnerEditsUploadAndQuantityIsAnOp() async throws {
        let (fixture, changes) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        let milk = try addFood("牛奶", quantity: 5, to: fridge, store: fixture.session.foodStore)
        _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        let food = RoutingFoodStore(personal: SwiftDataFoodStore(container: fixture.container), shared: fixture.inventory)

        var edited = milk
        edited.quantity = 4
        try food.upsert(edited)
        XCTAssertEqual(try food.activeItems(fridgeID: fridge.id).first?.quantity, 4)
        let opChange = try XCTUnwrap(changes().last)
        XCTAssertEqual(opChange.scope, .private)
        XCTAssertEqual(opChange.saves.count, 1, "only the op, the food record itself didn't change")
        XCTAssertNotEqual(opChange.saves.first?.recordName, milk.id.uuidString)

        let routing = RoutingFridgeStore(personal: fixture.personal, shared: fixture.inventory)
        try routing.rename(fridgeID: fridge.id, to: "全家的冰箱")
        XCTAssertEqual(try routing.loadAll().first?.fridge.name, "全家的冰箱")
        XCTAssertEqual(changes().last?.saves.first?.zoneID, SharedZone.id(fridgeID: fridge.id, kind: .structure))
        XCTAssertThrowsError(try routing.deleteFridge(fridge.id, moveHistoryTo: UUID())) {
            XCTAssertEqual($0 as? SharingRoutingError, .stopSharingFirst)
        }
    }

    // MARK: Deleting fridges with shared ones around

    private func consume(_ item: FoodItem, in store: FoodStore) throws {
        var eaten = item
        eaten.consumedAt = .now
        try store.upsert(eaten)
    }

    func testPersonalFridgeCanBeDeletedWhenOnlyASharedOneRemains() async throws {
        let (fixture, _) = try makeFixture()
        let shared = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: shared.id, backups: backups(fixture.session))
        let session = try AppBootstrap.makeSession(container: fixture.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: fixture.service).get()
        let pantry = try session.directory.create(name: "儲藏室", copyingLayoutFrom: nil)
        let jam = try addFood("果醬", quantity: 1, to: pantry, store: session.foodStore)
        try consume(jam, in: session.foodStore)

        let summary = try session.directory.deletionSummary(for: pantry.id)
        XCTAssertEqual(summary.remainingFridge.id, shared.id)
        try session.directory.delete(pantry.id)
        XCTAssertEqual(session.directory.fridges.map(\.id), [shared.id])
        XCTAssertEqual(try session.foodStore.consumedItems(fridgeID: shared.id).map(\.id), [jam.id], "history kept")
        XCTAssertTrue(try fixture.personal.loadExisting().isEmpty)
    }

    func testHistoryPrefersThePersonalFridge() async throws {
        let (fixture, _) = try makeFixture()
        let shared = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: shared.id, backups: backups(fixture.session))
        let session = try AppBootstrap.makeSession(container: fixture.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: fixture.service).get()
        // Make room: the limit is 2, so swap through a personal fridge.
        let pantry = try session.directory.create(name: "儲藏室", copyingLayoutFrom: nil)
        XCTAssertEqual(session.directory.historyPriority(pantry.id), 0)
        XCTAssertEqual(session.directory.historyPriority(shared.id), 2)
    }

    func testSharedFridgesCantBeDeletedDirectly() async throws {
        let (fixture, _) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        let session = try AppBootstrap.makeSession(container: fixture.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: fixture.service).get()
        let pantry = try session.directory.create(name: "儲藏室", copyingLayoutFrom: nil)
        XCTAssertThrowsError(try session.directory.delete(fridge.id)) { XCTAssertEqual($0 as? SharingRoutingError, .stopSharingFirst) }
        XCTAssertEqual(session.directory.fridges.count, 2)
        _ = pantry
    }

    func testFridgeThatStoppedSharingCanBeDeleted() async throws {
        let (fixture, changes) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        let milk = try addFood("牛奶", quantity: 1, to: fridge, store: fixture.session.foodStore)
        try consume(milk, in: fixture.session.foodStore)
        _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        try fixture.inventory.markUnshared(fridge.id)
        let session = try AppBootstrap.makeSession(container: fixture.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: fixture.service).get()
        let pantry = try session.directory.create(name: "儲藏室", copyingLayoutFrom: nil)

        try session.directory.delete(fridge.id)
        XCTAssertEqual(session.directory.fridges.map(\.id), [pantry.id])
        XCTAssertFalse(fixture.inventory.contains(fridge.id))
        XCTAssertEqual(changes().last?.deletedFridgeZones, [fridge.id], "its zones are removed from iCloud")
        XCTAssertEqual(try session.foodStore.consumedItems(fridgeID: pantry.id).map(\.id), [milk.id], "history moved to the personal fridge")
    }

    func testJoinedFridgesAreLeftNotDeletedAndNeverReceiveHistory() throws {
        let (fixture, _) = try makeFixture()
        let theirs = FridgeFactory.makeDefault(name: "朋友的")
        try fixture.inventory.store.apply(modifications: [
            SharedRecordCoder.encode(SharedFridgeFields(id: theirs.id, name: theirs.name, templateID: theirs.templateID,
                                                        layoutData: try StoredLayout.encode(theirs), createdAt: .now, updatedAt: .now),
                                     ownerName: "_friend", systemFields: nil)], deletions: [], scope: .shared)
        let session = try AppBootstrap.makeSession(container: fixture.container, mode: .inMemoryForTesting,
                                                   selection: InMemoryFridgeSelectionStore(), sharing: fixture.service).get()
        let mine = fixture.session.loadResult.fridge
        XCTAssertThrowsError(try session.directory.delete(theirs.id)) { XCTAssertEqual($0 as? SharingRoutingError, .leaveInstead) }
        XCTAssertThrowsError(try session.directory.delete(mine.id)) { XCTAssertEqual($0 as? FridgeDirectoryError, .noOwnFridgeLeft) }
        XCTAssertEqual(session.directory.fridges.count, 2, "nothing deleted")
    }

    func testFoodMovesBetweenPersonalAndSharedFridge() async throws {
        let (fixture, _) = try makeFixture()
        let shared = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: shared.id, backups: backups(fixture.session))
        let pantry = FridgeFactory.makeDefault(name: "儲藏室")
        let routing = RoutingFridgeStore(personal: fixture.personal, shared: fixture.inventory)
        try routing.create(pantry)
        XCTAssertEqual(Set(try routing.loadAll().map(\.fridge.id)), [shared.id, pantry.id])

        let personalFood = SwiftDataFoodStore(container: fixture.container)
        let food = RoutingFoodStore(personal: personalFood, shared: fixture.inventory)
        var jam = try addFood("果醬", quantity: 1, to: pantry, store: food)
        XCTAssertFalse(fixture.inventory.containsFood(jam.id))

        jam.fridgeID = shared.id
        jam.compartmentID = shared.cabinetCompartments[0].id
        try food.upsert(jam)
        XCTAssertTrue(fixture.inventory.containsFood(jam.id))
        XCTAssertTrue(try personalFood.activeItems(fridgeID: pantry.id).isEmpty, "moved, not copied")

        jam.fridgeID = pantry.id
        jam.compartmentID = pantry.cabinetCompartments[0].id
        try food.upsert(jam)
        XCTAssertFalse(fixture.inventory.containsFood(jam.id))
        XCTAssertEqual(try personalFood.activeItems(fridgeID: pantry.id).map(\.id), [jam.id])
    }

    func testParticipantCanEditFoodButNotStructure() throws {
        let inventory = SharedInventory(store: SharedStore(container: try SharedStore.makeContainer(inMemory: true)))
        var changes: [SharedInventory.Change] = []
        inventory.onLocalChange = { changes.append($0) }
        let fridge = FridgeFactory.makeDefault(name: "朋友的冰箱")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let fields = SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                        layoutData: try StoredLayout.encode(fridge), createdAt: date, updatedAt: date)
        try inventory.store.apply(modifications: [SharedRecordCoder.encode(fields, ownerName: "_friend", systemFields: nil)],
                                  deletions: [], scope: .shared)
        XCTAssertEqual(inventory.ownership(of: fridge.id), .sharedParticipant)
        XCTAssertNil(inventory.invitationURL(for: fridge.id), "only the owner hands out links")

        XCTAssertThrowsError(try inventory.rename(fridgeID: fridge.id, to: "我的")) { XCTAssertEqual($0 as? SharedStoreError, .ownerOnly) }
        XCTAssertThrowsError(try inventory.saveLayout(fridge)) { XCTAssertEqual($0 as? SharedStoreError, .ownerOnly) }
        XCTAssertThrowsError(try inventory.replaceMagnets([], fridgeID: fridge.id) { _ in nil }) { XCTAssertEqual($0 as? SharedStoreError, .ownerOnly) }
        XCTAssertTrue(changes.isEmpty)

        let item = FoodItem(id: UUID(), name: "豆腐", categoryID: "other", quantity: 2, unit: "盒", storedAt: date,
                            expirationDate: nil, storageReminderDays: nil, fridgeID: fridge.id,
                            compartmentID: fridge.cabinetCompartments[0].id, createdAt: date, updatedAt: date, consumedAt: nil)
        try inventory.upsert(item)
        XCTAssertEqual(changes.last?.scope, .shared)
        XCTAssertEqual(changes.last?.saves.first?.zoneID, SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: "_friend"))
        try inventory.saveDoorState(.open, fridgeID: fridge.id)
        XCTAssertEqual(changes.count, 1, "door state stays on this device")
    }

    func testOwnerMagnetsKeepTheirPhotos() async throws {
        let (fixture, changes) = try makeFixture()
        let fridge = fixture.session.loadResult.fridge
        _ = try await fixture.service.share(fridgeID: fridge.id, backups: backups(fixture.session))
        let magnets = RoutingMagnetStore(personal: SwiftDataMagnetStore(container: fixture.container), shared: fixture.inventory)
        let photoID = UUID()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let now = Date()
        let magnet = FridgeMagnet(id: UUID(), fridgeID: fridge.id, source: .photo, builtInAssetID: nil, localImageID: photoID,
                                  centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, rotation: 0, zIndex: 0,
                                  createdAt: now, updatedAt: now)
        try magnets.replaceMagnets([magnet], fridgeID: fridge.id, newImages: [photoID: png])
        XCTAssertEqual(try magnets.magnets(fridgeID: fridge.id), [magnet])
        XCTAssertEqual(try magnets.imageData(id: photoID), png)
        XCTAssertTrue(try magnets.storedImageIDs().contains(photoID))
        XCTAssertEqual(changes().last?.saves.count, 1)

        let missing = FridgeMagnet(id: UUID(), fridgeID: fridge.id, source: .photo, builtInAssetID: nil, localImageID: UUID(),
                                   centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, rotation: 0, zIndex: 1,
                                   createdAt: now, updatedAt: now)
        XCTAssertThrowsError(try magnets.replaceMagnets([magnet, missing], fridgeID: fridge.id, newImages: [:]))
        XCTAssertEqual(try magnets.magnets(fridgeID: fridge.id), [magnet], "all or nothing")
    }

    func testWithoutSharingTheSessionUsesPlainStores() throws {
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        XCTAssertNil(session.sharing)
        XCTAssertTrue(session.fridgeStore is SwiftDataFridgeStore)
        XCTAssertTrue(session.foodStore is SwiftDataFoodStore)
    }
}
