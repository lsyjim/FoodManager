import CloudKit
import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5D-1: sharing policy, the shared-fridge store, CloudKit record mapping and the quantity ledger. No network:
/// records are built locally, exactly as `CKSyncEngine` would deliver them.
final class SharingFoundationTests: XCTestCase {
    private let owner = "_owner_record_name"

    // MARK: Policy

    func testDisabledPolicyHidesEverythingWithoutPaywall() {
        let off = SharingPolicy(sharedRefrigeratorsEnabled: false, sharedRefrigeratorsRequirePremium: true, accessRequestsSupported: true)
        XCTAssertFalse(off.isActive)
        XCTAssertEqual(off.startSharingGate(hasPremium: false), .disabled, "never a paywall while the feature is off")
        XCTAssertEqual(off.joinGate, .disabled, "an invitation link can't bypass the switch")
    }

    func testOlderSystemsGetNoSharing() {
        let policy = SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false, accessRequestsSupported: false)
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.startSharingGate(hasPremium: true), .unsupportedSystem)
        XCTAssertEqual(policy.joinGate, .unsupportedSystem)
    }

    func testOnlyTheOwnerNeedsPremium() {
        let future = SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: true, accessRequestsSupported: true)
        XCTAssertEqual(future.startSharingGate(hasPremium: false), .requiresPremium)
        XCTAssertEqual(future.startSharingGate(hasPremium: true), .allowed)
        XCTAssertEqual(future.joinGate, .allowed)
    }

    func testDevelopmentPolicyNeedsNoPremium() {
        let current = SharingPolicy.current
        XCTAssertTrue(current.sharedRefrigeratorsEnabled, "Debug builds enable sharing for development")
        XCTAssertFalse(current.sharedRefrigeratorsRequirePremium)
        XCTAssertEqual(current.accessRequestsSupported, SharingPolicy.osSupportsAccessRequests)
    }

    func testSelectorLabelsAndLimit() {
        XCTAssertNil(SharedFridgeOwnership.personalOwned.selectorLabel)
        XCTAssertEqual(SharedFridgeOwnership.sharedOwned.selectorLabel, "已共享 · 我是主人")
        XCTAssertEqual(SharedFridgeOwnership.sharedParticipant.selectorLabel, "參與共享")
        XCTAssertEqual(SharedFridgeOwnership.pendingInvitation.selectorLabel, "等待主人同意")
        XCTAssertEqual(SharedFridgeOwnership.unavailableOrRevoked.selectorLabel, "共享無法存取")

        XCTAssertTrue(FridgePolicy.canAddFridge(personal: 1, shared: []))
        XCTAssertFalse(FridgePolicy.canAddFridge(personal: 1, shared: [.sharedParticipant]), "joined fridges count")
        XCTAssertFalse(FridgePolicy.canAddFridge(personal: 1, shared: [.pendingInvitation]), "a pending request reserves a slot")
        XCTAssertTrue(FridgePolicy.canAddFridge(personal: 1, shared: [.unavailableOrRevoked]))
        XCTAssertEqual(FridgePolicy.fridgeCount(personal: 0, shared: [.sharedOwned, .sharedParticipant]), 2)
    }

    // MARK: Quantity ledger

    private func op(_ delta: Decimal, id: UUID = UUID(), at offset: TimeInterval = 0) -> QuantityOp {
        QuantityOp(id: id, foodID: UUID(), delta: delta, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset))
    }

    func testConcurrentDecrementsBothCount() {
        XCTAssertEqual(QuantityLedger.quantity(base: 5, folded: [], ops: [op(-1), op(-2)]), 2)
    }

    func testDuplicateDeliveryIsCountedOnce() {
        let take = op(-1)
        XCTAssertEqual(QuantityLedger.quantity(base: 5, folded: [], ops: [take, take, take]), 4)
    }

    func testFoldedOpsAreIgnoredAndResultNeverNegative() {
        let folded = op(-3)
        XCTAssertEqual(QuantityLedger.quantity(base: 2, folded: [folded.id], ops: [folded]), 2)
        XCTAssertEqual(QuantityLedger.quantity(base: 1, folded: [], ops: [op(-2)]), 0)
    }

    func testCompactionKeepsTheResultExact() {
        let ops = [op(-3, at: 0), op(Decimal(string: "1.5")!, at: 10), op(5, at: 100), op(-1, at: 200)]
        let before = QuantityLedger.quantity(base: 1, folded: [], ops: ops)
        let compaction = QuantityLedger.compact(base: 1, folded: [], ops: ops, olderThan: Date(timeIntervalSince1970: 1_800_000_050))
        XCTAssertEqual(compaction.foldedOps.count, 2)
        XCTAssertEqual(compaction.base, Decimal(string: "-0.5")!, "the base may go negative")
        let remaining = ops.filter { !compaction.foldedOps.contains($0.id) }
        XCTAssertEqual(QuantityLedger.quantity(base: compaction.base, folded: Set(compaction.folded), ops: remaining), before)
        // A late re-delivery of a folded op changes nothing.
        XCTAssertEqual(QuantityLedger.quantity(base: compaction.base, folded: Set(compaction.folded), ops: ops), before)
    }

    func testDeltaValidation() {
        XCTAssertFalse(QuantityLedger.isValidDelta(0))
        XCTAssertFalse(QuantityLedger.isValidDelta(.nan))
        XCTAssertFalse(QuantityLedger.isValidDelta(2_000_000))
        XCTAssertTrue(QuantityLedger.isValidDelta(-1))
    }

    // MARK: Zones and record coding

    func testZoneNamesRoundTrip() {
        let id = UUID()
        let zone = SharedZone.id(fridgeID: id, kind: .inventory, ownerName: owner)
        XCTAssertEqual(SharedZone.parse(zone)?.fridgeID, id)
        XCTAssertEqual(SharedZone.parse(zone)?.kind, .inventory)
        XCTAssertNil(SharedZone.parse(CKRecordZone.ID(zoneName: CKRecordZone.ID.defaultZoneName, ownerName: owner)))
        XCTAssertNil(SharedZone.parse(CKRecordZone.ID(zoneName: "Fridge-not-a-uuid-Inventory", ownerName: owner)))
        XCTAssertNil(SharedZone.parse(CKRecordZone.ID(zoneName: "Fridge-\(id.uuidString)-Admin", ownerName: owner)))
    }

    private func fridgeFields(_ fridge: Fridge = FridgeFactory.makeDefault(name: "共用冰箱")) throws -> SharedFridgeFields {
        SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID, layoutData: try StoredLayout.encode(fridge),
                           createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func foodFields(fridge: Fridge, base: Decimal = 5, name: String = "牛奶") -> SharedFoodFields {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return SharedFoodFields(id: UUID(), fridgeID: fridge.id, compartmentID: fridge.cabinetCompartments[0].id, name: name,
                                categoryID: "dairy", baseQuantity: base, foldedOpIDs: [], unit: "瓶", storedAt: date,
                                expirationDate: nil, storageReminderDays: 3, createdAt: date, updatedAt: date, consumedAt: nil)
    }

    func testFridgeAndFoodRoundTrip() throws {
        let fridge = FridgeFactory.makeDefault(name: "共用冰箱")
        let fields = try fridgeFields(fridge)
        XCTAssertEqual(SharedRecordCoder.decode(SharedRecordCoder.encode(fields, ownerName: owner, systemFields: nil)), .fridge(fields))
        let food = foodFields(fridge: fridge, base: Decimal(string: "1.5")!)
        XCTAssertEqual(SharedRecordCoder.decode(SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil)), .food(food))
        let take = QuantityOp(id: UUID(), foodID: food.id, delta: -1, createdAt: food.createdAt)
        XCTAssertEqual(SharedRecordCoder.decode(SharedRecordCoder.encode(take, fridgeID: fridge.id, ownerName: owner, systemFields: nil)),
                       .quantityOp(take, fridgeID: fridge.id))
    }

    func testStructureFromTheInventoryZoneIsIgnored() throws {
        let fields = try fridgeFields()
        // A participant (who can write the inventory zone) plants a "fridge" record there to rename the fridge.
        let forged = CKRecord(recordType: SharedRecordType.fridge,
                              recordID: CKRecord.ID(recordName: fields.id.uuidString,
                                                    zoneID: SharedZone.id(fridgeID: fields.id, kind: .inventory, ownerName: owner)))
        let genuine = SharedRecordCoder.encode(fields, ownerName: owner, systemFields: nil)
        for key in genuine.allKeys() { forged[key] = genuine[key] }
        forged["name"] = "改名了"
        XCTAssertNil(SharedRecordCoder.decode(forged))
    }

    func testFoodBelongsToItsZonesFridge() throws {
        let fridge = FridgeFactory.makeDefault(), other = FridgeFactory.makeDefault()
        var food = foodFields(fridge: fridge)
        let record = SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil)
        food.fridgeID = other.id
        guard case let .food(decoded)? = SharedRecordCoder.decode(record) else { return XCTFail("decodes") }
        XCTAssertEqual(decoded.fridgeID, fridge.id, "fridge comes from the zone, not a field")

        let inStructure = CKRecord(recordType: SharedRecordType.food,
                                   recordID: CKRecord.ID(recordName: UUID().uuidString,
                                                         zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: owner)))
        for key in record.allKeys() { inStructure[key] = record[key] }
        XCTAssertNil(SharedRecordCoder.decode(inStructure), "food can't be planted into the read-only zone either")
    }

    func testInvalidRecordsAreIgnored() throws {
        let fridge = FridgeFactory.makeDefault()
        XCTAssertNil(SharedRecordCoder.decode(SharedRecordCoder.encode(foodFields(fridge: fridge, name: "  "), ownerName: owner, systemFields: nil)))
        XCTAssertNil(SharedRecordCoder.decode(SharedRecordCoder.encode(foodFields(fridge: fridge, base: 5_000_000), ownerName: owner, systemFields: nil)))

        var layout = try fridgeFields(fridge)
        layout.layoutData = Data("{}".utf8)
        XCTAssertNil(SharedRecordCoder.decode(SharedRecordCoder.encode(layout, ownerName: owner, systemFields: nil)))
        var name = try fridgeFields(fridge)
        name.name = String(repeating: "冰", count: 40)
        XCTAssertNil(SharedRecordCoder.decode(SharedRecordCoder.encode(name, ownerName: owner, systemFields: nil)))

        let zero = QuantityOp(id: UUID(), foodID: UUID(), delta: 0, createdAt: .now)
        XCTAssertNil(SharedRecordCoder.decode(SharedRecordCoder.encode(zero, fridgeID: fridge.id, ownerName: owner, systemFields: nil)))
        let unknown = CKRecord(recordType: "Admin", recordID: CKRecord.ID(recordName: UUID().uuidString,
                                                                        zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory)))
        XCTAssertNil(SharedRecordCoder.decode(unknown))
    }

    func testSystemFieldsRestoreTheSameRecord() throws {
        let record = SharedRecordCoder.encode(try fridgeFields(), ownerName: owner, systemFields: nil)
        let restored = SharedRecordCoder.restore(systemFields: SharedRecordCoder.systemFields(of: record))
        XCTAssertEqual(restored?.recordID, record.recordID)
        XCTAssertEqual(restored?.recordType, SharedRecordType.fridge)
    }

    // MARK: Store

    private func makeStore() throws -> SharedStore {
        SharedStore(container: try SharedStore.makeContainer(inMemory: true))
    }

    func testSharedStoreIsASeparateFile() {
        XCTAssertNotEqual(SharedStore.defaultURL, SwiftDataFridgeStore.defaultStoreURL)
        XCTAssertEqual(SharedStore.defaultURL.deletingLastPathComponent(), SwiftDataFridgeStore.defaultStoreURL.deletingLastPathComponent())
        XCTAssertEqual(SharedStore.defaultURL.lastPathComponent, "Shared.store")
    }

    func testParticipantReceivesFridgeFoodAndOps() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault(name: "共用冰箱")
        let food = foodFields(fridge: fridge)
        let takeOne = QuantityOp(id: UUID(), foodID: food.id, delta: -1, createdAt: food.createdAt)
        let takeTwo = QuantityOp(id: UUID(), foodID: food.id, delta: -2, createdAt: food.createdAt)
        let records = [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: owner, systemFields: nil),
                       SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil),
                       SharedRecordCoder.encode(takeOne, fridgeID: fridge.id, ownerName: owner, systemFields: nil),
                       SharedRecordCoder.encode(takeTwo, fridgeID: fridge.id, ownerName: owner, systemFields: nil)]
        let report = try store.apply(modifications: records, deletions: [], scope: .shared)
        XCTAssertEqual(report, SharedApplyReport(applied: 4, ignored: 0, deleted: 0))
        XCTAssertEqual(try store.quantity(foodID: food.id), 2, "5 − 1 − 2")
        XCTAssertEqual(try store.fridges().map(\.ownership), [.sharedParticipant])

        // Re-delivery of the same op doesn't count twice.
        try store.apply(modifications: [records[2]], deletions: [], scope: .shared)
        XCTAssertEqual(try store.quantity(foodID: food.id), 2)
    }

    func testLocalQuantityChangeIsAnOp() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault()
        let food = foodFields(fridge: fridge)
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: owner, systemFields: nil),
                                        SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil)], deletions: [], scope: .shared)
        let opID = try store.recordQuantityChange(foodID: food.id, delta: -1)
        XCTAssertEqual(try store.quantity(foodID: food.id), 4)
        XCTAssertThrowsError(try store.recordQuantityChange(foodID: food.id, delta: 0))
        XCTAssertThrowsError(try store.recordQuantityChange(foodID: UUID(), delta: 1))

        let outgoing = try store.outgoingRecord(for: CKRecord.ID(recordName: opID.uuidString,
                                                                 zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: owner)),
                                                scope: .shared)
        XCTAssertEqual(outgoing?.recordType, SharedRecordType.quantityOp)
        XCTAssertEqual(outgoing?["delta"] as? String, "-1")
    }

    func testParticipantNeverUploadsStructure() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault()
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: owner, systemFields: nil)],
                        deletions: [], scope: .shared)
        let structureID = CKRecord.ID(recordName: fridge.id.uuidString,
                                      zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: owner))
        XCTAssertNil(try store.outgoingRecord(for: structureID, scope: .shared))
        XCTAssertNil(try store.outgoingRecord(for: structureID, scope: .private), "wrong scope for this fridge")
    }

    func testOwnerUploadsStructure() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault(name: "我家")
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: CKCurrentUserDefaultName, systemFields: nil)],
                        deletions: [], scope: .private)
        let structureID = CKRecord.ID(recordName: fridge.id.uuidString, zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure))
        XCTAssertEqual(try store.outgoingRecord(for: structureID, scope: .private)?["name"] as? String, "我家")
        XCTAssertEqual(try store.fridges().map(\.ownership), [.personalOwned], "not shared until a share exists")
    }

    func testSameFridgeCanNotSwitchRole() throws {
        let store = try makeStore()
        let fields = try fridgeFields()
        try store.apply(modifications: [SharedRecordCoder.encode(fields, ownerName: CKCurrentUserDefaultName, systemFields: nil)],
                        deletions: [], scope: .private)
        var renamed = fields
        renamed.name = "別人的"
        let report = try store.apply(modifications: [SharedRecordCoder.encode(renamed, ownerName: owner, systemFields: nil)],
                                     deletions: [], scope: .shared)
        XCTAssertEqual(report.ignored, 1)
        XCTAssertEqual(try store.fridges().map(\.name), [fields.name])
    }

    func testDeletingFoodRemovesItsOps() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault()
        let food = foodFields(fridge: fridge)
        let take = QuantityOp(id: UUID(), foodID: food.id, delta: -1, createdAt: food.createdAt)
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: owner, systemFields: nil),
                                        SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil),
                                        SharedRecordCoder.encode(take, fridgeID: fridge.id, ownerName: owner, systemFields: nil)],
                        deletions: [], scope: .shared)
        let foodID = CKRecord.ID(recordName: food.id.uuidString, zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: owner))
        let report = try store.apply(modifications: [], deletions: [(foodID, SharedRecordType.food)], scope: .shared)
        XCTAssertEqual(report.deleted, 1)
        XCTAssertNil(try store.quantity(foodID: food.id))
        let context = store.makeContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SharedQuantityOpRecord>()), 0)
    }

    func testRevokedZoneLeavesOnlyAnUnavailablePlaceholder() throws {
        let store = try makeStore()
        let fridge = FridgeFactory.makeDefault(name: "共用冰箱")
        let food = foodFields(fridge: fridge)
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(fridge), ownerName: owner, systemFields: nil),
                                        SharedRecordCoder.encode(food, ownerName: owner, systemFields: nil)], deletions: [], scope: .shared)
        try store.zoneWasDeleted(SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: owner), scope: .shared)
        XCTAssertEqual(try store.fridges().map(\.ownership), [.unavailableOrRevoked])
        XCTAssertNil(try store.quantity(foodID: food.id), "no inventory stays readable after revocation")
        XCTAssertTrue(FridgePolicy.canAddFridge(personal: 1, shared: try store.ownerships()))

        let foodID = CKRecord.ID(recordName: food.id.uuidString, zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: owner))
        XCTAssertNil(try store.outgoingRecord(for: foodID, scope: .shared), "nothing is sent for an unavailable fridge")
    }

    func testAccountChangePurgesParticipantData() throws {
        let store = try makeStore()
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(), ownerName: owner, systemFields: nil)],
                        deletions: [], scope: .shared)
        try store.apply(modifications: [SharedRecordCoder.encode(try fridgeFields(), ownerName: CKCurrentUserDefaultName, systemFields: nil)],
                        deletions: [], scope: .private)
        try store.purgeAll(role: .participant)
        XCTAssertEqual(try store.fridges().map(\.role), [.owner])
    }

    func testSyncStateIsStoredPerScope() throws {
        let store = try makeStore()
        try store.saveSyncState(Data([1]), scope: "private")
        try store.saveSyncState(Data([2]), scope: "shared")
        try store.saveSyncState(Data([3]), scope: "private")
        XCTAssertEqual(try store.syncState(scope: "private"), Data([3]))
        XCTAssertEqual(try store.syncState(scope: "shared"), Data([2]))
        try store.saveSyncState(nil, scope: "shared")
        XCTAssertNil(try store.syncState(scope: "shared"))
    }

    // MARK: Engine gate and fallback fetch

    func testEngineNeverStartsUnlessActive() {
        let on = SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false, accessRequestsSupported: true)
        let off = SharingPolicy(sharedRefrigeratorsEnabled: false, sharedRefrigeratorsRequirePremium: false, accessRequestsSupported: true)
        var opened = 0
        let factory: () throws -> SharedStore = {
            opened += 1
            return SharedStore(container: try SharedStore.makeContainer(inMemory: true))
        }
        XCTAssertNil(SharedSyncEngine.make(policy: off, mode: .persistent, cloudSyncEnabled: true, storeFactory: factory))
        XCTAssertNil(SharedSyncEngine.make(policy: on, mode: .inMemoryForTesting, cloudSyncEnabled: true, storeFactory: factory))
        XCTAssertNil(SharedSyncEngine.make(policy: on, mode: .persistent, cloudSyncEnabled: false, storeFactory: factory))
        XCTAssertEqual(opened, 0, "not even the shared store is opened")
    }

    func testFallbackFetchOnlyWhileVisibleAndNeverOverlapping() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduler = SharedFetchScheduler()
        XCTAssertFalse(scheduler.beginIfDue(now: start), "nothing shared on screen")
        scheduler.sharedFridgeVisible = true
        XCTAssertFalse(scheduler.beginIfDue(now: start), "app in background")
        scheduler.appActive = true
        XCTAssertTrue(scheduler.beginIfDue(now: start))
        XCTAssertFalse(scheduler.beginIfDue(now: start.addingTimeInterval(60)), "previous fetch still running")
        scheduler.finish(success: true)
        XCTAssertFalse(scheduler.beginIfDue(now: start.addingTimeInterval(29)))
        XCTAssertTrue(scheduler.beginIfDue(now: start.addingTimeInterval(30)))
    }

    func testFallbackFetchBacksOff() {
        var scheduler = SharedFetchScheduler()
        XCTAssertEqual(scheduler.currentInterval, 30)
        scheduler.finish(success: false)
        XCTAssertEqual(scheduler.currentInterval, 60)
        scheduler.finish(success: false)
        XCTAssertEqual(scheduler.currentInterval, 120)
        for _ in 0..<10 { scheduler.finish(success: false) }
        XCTAssertEqual(scheduler.currentInterval, 300)
        scheduler.finish(success: true)
        XCTAssertEqual(scheduler.currentInterval, 30)
    }
}
