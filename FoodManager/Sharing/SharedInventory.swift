import CloudKit
import Foundation
import SwiftData

/// Shared fridges in domain terms (`Fridge`, `FoodItem`, `FridgeMagnet`), for the routing stores. Every local write
/// reports the CloudKit records to upload or delete through `onLocalChange` (wired to `SharedSyncEngine`).
///
/// Roles: the owner may change everything; a participant may only change food. Structure writes by a participant
/// throw `ownerOnly` here, and the server rejects them as well (read-only structure share).
final class SharedInventory {
    struct Change: Equatable {
        var saves: [CKRecord.ID] = []
        var deletes: [CKRecord.ID] = []
        var scope: SharedDatabaseScope
    }

    let store: SharedStore
    var onLocalChange: ((Change) -> Void)?
    /// Fridges whose shared copy must not be used: leftovers of a sharing attempt that didn't complete (the personal
    /// fridge is still the real one). Treated as if they weren't in this store.
    var hiddenFridgeIDs: () -> Set<UUID> = { [] }

    init(store: SharedStore) {
        self.store = store
    }

    // MARK: Fridges

    /// Fridges that can be shown and used (pending and unavailable ones are listed separately via `store`).
    func loadAll() throws -> [FridgeLoadResult] {
        let hidden = hiddenFridgeIDs()
        return try store.makeContext().fetch(FetchDescriptor<SharedFridgeRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.status == .active && !hidden.contains($0.id) }
            .map(Self.loadResult)
    }

    func contains(_ fridgeID: UUID) -> Bool {
        guard !hiddenFridgeIDs().contains(fridgeID) else { return false }
        return (try? fridgeRow(fridgeID, in: store.makeContext())) != nil
    }

    func role(of fridgeID: UUID) -> SharedFridgeRole? {
        (try? fridgeRow(fridgeID, in: store.makeContext()))?.role
    }

    func ownership(of fridgeID: UUID) -> SharedFridgeOwnership? {
        guard !hiddenFridgeIDs().contains(fridgeID) else { return nil }
        return (try? fridgeRow(fridgeID, in: store.makeContext()))?.ownership
    }

    func zoneOwnerName(of fridgeID: UUID) -> String? {
        (try? fridgeRow(fridgeID, in: store.makeContext()))?.zoneOwnerName
    }

    func invitationURL(for fridgeID: UUID) -> URL? {
        guard let row = try? fridgeRow(fridgeID, in: store.makeContext()), row.role == .owner else { return nil }
        return row.inventoryShareURL.flatMap(URL.init(string:))
    }

    func saveLayout(_ fridge: Fridge) throws {
        let errors = FridgeLayoutEngine.validate(fridge)
        guard errors.isEmpty else { throw FridgeStoreError.invalidLayout(errors) }
        let context = store.makeContext()
        let row = try ownedRow(fridge.id, in: context)
        row.name = fridge.name
        row.templateID = fridge.templateID
        row.layoutData = try StoredLayout.encode(fridge)
        row.updatedAt = .now
        try context.save()
        report(saves: [structureID(row)], scope: .private)
    }

    func rename(fridgeID: UUID, to name: String) throws {
        let context = store.makeContext()
        let row = try ownedRow(fridgeID, in: context)
        row.name = name
        row.updatedAt = .now
        try context.save()
        report(saves: [structureID(row)], scope: .private)
    }

    /// This device's door state only (never uploaded).
    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws {
        let context = store.makeContext()
        guard let row = try fridgeRow(fridgeID, in: context) else { throw FridgeStoreError.fridgeNotFound }
        row.lastDoorStateRaw = state.rawValue
        try context.save()
    }

    /// Owner: copies a personal fridge (from a verified backup) into the shared store as a new, not yet shared
    /// fridge in the owner's custom zones. Returns every record to upload. Nothing is uploaded or deleted here.
    func importOwnedFridge(_ fridge: BackupFridge, foods: [BackupFood], magnets: [FridgeMagnet],
                           images: [UUID: Data]) throws -> [CKRecord.ID] {
        let context = store.makeContext()
        guard try fridgeRow(fridge.id, in: context) == nil else { throw SharedStoreError.alreadyShared }
        let domain = fridge.fridge
        guard FridgeLayoutEngine.validate(domain).isEmpty else { throw FridgeStoreError.invalidLayout(FridgeLayoutEngine.validate(domain)) }
        let row = SharedFridgeRecord(id: fridge.id, role: .owner, zoneOwnerName: CKCurrentUserDefaultName)
        row.name = fridge.name
        row.templateID = fridge.templateID
        row.layoutData = try StoredLayout.encode(domain)
        row.lastDoorStateRaw = fridge.doorState.rawValue
        row.createdAt = fridge.createdAt
        row.updatedAt = .now
        context.insert(row)
        var ids = [structureID(row)]
        for food in foods where food.fridgeID == fridge.id {
            guard let quantity = food.decimalQuantity else { throw SharedStoreError.invalidQuantity }
            let foodRow = SharedFoodRecord(id: food.id, fridgeID: fridge.id)
            Self.apply(food.item, to: foodRow)
            foodRow.baseQuantity = quantity
            context.insert(foodRow)
            ids.append(inventoryID(food.id, row))
        }
        for magnet in magnets where magnet.fridgeID == fridge.id {
            let magnetRow = SharedMagnetRecord(id: magnet.id, fridgeID: fridge.id)
            try Self.apply(magnet, to: magnetRow, imageData: magnet.localImageID.flatMap { images[$0] })
            context.insert(magnetRow)
            ids.append(structureID(magnet.id, row))
        }
        try context.save()
        return ids
    }

    /// Records of a fridge that the server hasn't confirmed yet (no stored system fields).
    func unconfirmedRecords(of fridgeID: UUID) throws -> Int {
        let context = store.makeContext()
        var count = try fridgeRow(fridgeID, in: context)?.systemFields == nil ? 1 : 0
        count += try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
            .filter { $0.systemFields == nil }.count
        count += try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
            .filter { $0.systemFields == nil }.count
        return count
    }

    /// Owner: both zone shares exist on the server.
    func markShared(_ fridgeID: UUID, invitationURL: URL?, structureURL: URL?) throws {
        let context = store.makeContext()
        let row = try ownedRow(fridgeID, in: context)
        row.isShared = true
        row.inventoryShareURL = invitationURL?.absoluteString
        row.structureShareURL = structureURL?.absoluteString
        try context.save()
        // Approved members find the structure share through this record.
        if structureURL != nil { report(saves: [inventoryID(row.id, row)], scope: .private) }
    }

    /// Owner: both shares were deleted. The fridge stays with the owner (still in the private custom zones).
    func markUnshared(_ fridgeID: UUID) throws {
        let context = store.makeContext()
        let row = try ownedRow(fridgeID, in: context)
        row.isShared = false
        row.inventoryShareURL = nil
        row.structureShareURL = nil
        try context.save()
        report(deletes: [inventoryID(row.id, row)], scope: .private)
    }

    // MARK: Food

    func items(fridgeID: UUID) throws -> [FoodItem] {
        let context = store.makeContext()
        let rows = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.fridgeID == fridgeID },
                                                                       sortBy: [SortDescriptor(\.storedAt), SortDescriptor(\.name)]))
        let ops = Dictionary(grouping: try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
            .map(\.op), by: \.foodID)
        return rows.map { Self.item(from: $0, ops: ops[$0.id] ?? []) }
    }

    func allItems() throws -> [FoodItem] {
        let hidden = hiddenFridgeIDs()
        let context = store.makeContext()
        let ops = Dictionary(grouping: try context.fetch(FetchDescriptor<SharedQuantityOpRecord>()).map(\.op), by: \.foodID)
        return try context.fetch(FetchDescriptor<SharedFoodRecord>()).filter { !hidden.contains($0.fridgeID) }
            .map { Self.item(from: $0, ops: ops[$0.id] ?? []) }
    }

    func containsFood(_ id: UUID) -> Bool {
        guard let food = try? store.makeContext().fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first else {
            return false
        }
        return !hiddenFridgeIDs().contains(food.fridgeID)
    }

    /// Creates or edits a food. A quantity change becomes a new op (never an overwrite of the base), so edits on two
    /// devices add up. Moving to another shared fridge recreates the food in that fridge's zone.
    func upsert(_ item: FoodItem) throws {
        let context = store.makeContext()
        guard let fridge = try fridgeRow(item.fridgeID, in: context), fridge.status == .active else { throw FoodStoreError.notFound }
        let id = item.id
        var saves: [CKRecord.ID] = []
        var deletes: [(CKRecord.ID, SharedDatabaseScope)] = []
        let existing = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first
        if let existing, existing.fridgeID == item.fridgeID {
            let ops = try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.foodID == id })).map(\.op)
            let current = QuantityLedger.quantity(base: existing.baseQuantity, folded: Set(existing.foldedOpIDs), ops: ops)
            if item.quantity != current {
                let delta = item.quantity - current
                guard QuantityLedger.isValidDelta(delta) else { throw SharedStoreError.invalidQuantity }
                let op = QuantityOp(id: UUID(), foodID: id, delta: delta, createdAt: .now)
                context.insert(SharedQuantityOpRecord(op, fridgeID: item.fridgeID))
                saves.append(inventoryID(op.id, fridge))
            }
            if Self.item(from: existing, ops: ops).withQuantity(item.quantity) != item {
                Self.apply(item, to: existing)
                saves.append(inventoryID(id, fridge))
            }
        } else {
            if let existing, let oldFridge = try fridgeRow(existing.fridgeID, in: context) {
                deletes += try deleteFoodRows(id, oldFridge: oldFridge, in: context).map { ($0, oldFridge.role.scope) }
            }
            let row = SharedFoodRecord(id: id, fridgeID: item.fridgeID)
            Self.apply(item, to: row)
            row.baseQuantity = item.quantity
            context.insert(row)
            saves.append(inventoryID(id, fridge))
        }
        try context.save()
        for scope in Set(deletes.map(\.1)) {
            report(deletes: deletes.filter { $0.1 == scope }.map(\.0), scope: scope)
        }
        report(saves: saves, scope: fridge.role.scope)
    }

    func delete(id: UUID) throws {
        let context = store.makeContext()
        guard let food = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first,
              let fridge = try fridgeRow(food.fridgeID, in: context) else { throw FoodStoreError.notFound }
        let deleted = try deleteFoodRows(id, oldFridge: fridge, in: context)
        try context.save()
        report(deletes: deleted, scope: fridge.role.scope)
    }

    // MARK: Magnets

    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] {
        try store.makeContext().fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
            .compactMap(Self.magnet).sorted { ($0.zIndex, $0.id.uuidString) < ($1.zIndex, $1.id.uuidString) }
    }

    func allMagnets() throws -> [FridgeMagnet] {
        let hidden = hiddenFridgeIDs()
        return try store.makeContext().fetch(FetchDescriptor<SharedMagnetRecord>()).filter { !hidden.contains($0.fridgeID) }
            .compactMap(Self.magnet)
    }

    func imageData(id: UUID) throws -> Data? {
        try store.makeContext().fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.imageID == id }))
            .lazy.compactMap(\.imageData).first
    }

    func storedImageIDs() throws -> Set<UUID> {
        Set(try store.makeContext().fetch(FetchDescriptor<SharedMagnetRecord>()).filter { $0.imageData != nil }.compactMap(\.imageID))
    }

    /// Owner only. `imageData` supplies the bytes of each photo (new photos, other fridges, the personal store).
    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID, imageData: (UUID) -> Data?) throws {
        let context = store.makeContext()
        let fridge = try ownedRow(fridgeID, in: context)
        let existing = try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let keep = Set(magnets.map(\.id))
        var deletes: [CKRecord.ID] = []
        for row in existing where !keep.contains(row.id) {
            deletes.append(structureID(row.id, fridge))
            context.delete(row)
        }
        var saves: [CKRecord.ID] = []
        for magnet in magnets {
            let row = existing.first { $0.id == magnet.id } ?? {
                let row = SharedMagnetRecord(id: magnet.id, fridgeID: fridgeID)
                context.insert(row)
                return row
            }()
            if Self.magnet(from: row) == magnet { continue }
            let bytes = magnet.localImageID.flatMap { id in row.imageID == id ? row.imageData : nil } ?? magnet.localImageID.flatMap(imageData)
            try Self.apply(magnet, to: row, imageData: bytes)
            saves.append(structureID(magnet.id, fridge))
        }
        try context.save()
        report(deletes: deletes, scope: .private)
        report(saves: saves, scope: .private)
    }

    // MARK: Mapping

    private static func loadResult(_ row: SharedFridgeRecord) -> FridgeLoadResult {
        let template = FridgeTemplateCatalog.template(id: row.templateID)
        let door = DoorState(rawValue: row.lastDoorStateRaw) ?? .closed
        if let layout = try? StoredLayout.decode(row.layoutData) {
            let fridge = Fridge(id: row.id, name: row.name, templateID: template.id, lastDoorState: door,
                                cabinetCompartments: layout.cabinetCompartments, doorCompartments: layout.doorCompartments)
            if FridgeLayoutEngine.validate(fridge).isEmpty { return FridgeLoadResult(fridge: fridge, recovery: .none) }
        }
        var fallback = FridgeFactory.makeDefault(template: template, name: row.name, idSeed: row.id)
        fallback.lastDoorState = door
        return FridgeLoadResult(fridge: Fridge(id: row.id, name: row.name, templateID: template.id, lastDoorState: door,
                                               cabinetCompartments: fallback.cabinetCompartments, doorCompartments: fallback.doorCompartments),
                                recovery: .replacedWithDefault)
    }

    private static func item(from row: SharedFoodRecord, ops: [QuantityOp]) -> FoodItem {
        FoodItem(id: row.id, name: row.name, categoryID: row.categoryID,
                 quantity: QuantityLedger.quantity(base: row.baseQuantity, folded: Set(row.foldedOpIDs), ops: ops),
                 unit: row.unit, storedAt: row.storedAt, expirationDate: row.expirationDate,
                 storageReminderDays: row.storageReminderDays, fridgeID: row.fridgeID, compartmentID: row.compartmentID,
                 createdAt: row.createdAt, updatedAt: row.updatedAt, consumedAt: row.consumedAt)
    }

    /// Every field except the quantity (which lives in the ledger).
    private static func apply(_ item: FoodItem, to row: SharedFoodRecord) {
        row.name = item.name
        row.categoryID = item.categoryID
        row.unit = item.unit
        row.storedAt = item.storedAt
        row.expirationDate = item.expirationDate
        row.storageReminderDays = item.storageReminderDays
        row.compartmentID = item.compartmentID
        row.createdAt = item.createdAt
        row.updatedAt = item.updatedAt
        row.consumedAt = item.consumedAt
    }

    private static func magnet(from row: SharedMagnetRecord) -> FridgeMagnet? {
        guard let source = MagnetSource(rawValue: row.sourceRaw) else { return nil }
        return FridgeMagnet(id: row.id, fridgeID: row.fridgeID, source: source, builtInAssetID: row.builtInAssetID,
                            localImageID: row.imageID, centerX: row.centerX, centerY: row.centerY, width: row.width,
                            height: row.height, rotation: row.rotation, zIndex: row.zIndex, createdAt: row.createdAt,
                            updatedAt: row.updatedAt, style: row.styleRaw.flatMap(MagnetStyle.init(rawValue:)) ?? .original)
    }

    private static func apply(_ magnet: FridgeMagnet, to row: SharedMagnetRecord, imageData: Data?) throws {
        if magnet.source == .photo {
            guard let imageData, imageData.count <= SharedRecordCoder.maxImageBytes else { throw SharedStoreError.photoMissing }
            row.imageData = imageData
        } else {
            row.imageData = nil
        }
        row.sourceRaw = magnet.source.rawValue
        row.builtInAssetID = magnet.builtInAssetID
        row.imageID = magnet.localImageID
        row.styleRaw = magnet.style == .original ? nil : magnet.style.rawValue
        row.centerX = magnet.centerX
        row.centerY = magnet.centerY
        row.width = magnet.width
        row.height = magnet.height
        row.rotation = magnet.rotation
        row.zIndex = magnet.zIndex
        row.createdAt = magnet.createdAt
        row.updatedAt = magnet.updatedAt
    }

    // MARK: Helpers

    private func fridgeRow(_ id: UUID, in context: ModelContext) throws -> SharedFridgeRecord? {
        try context.fetch(FetchDescriptor<SharedFridgeRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func ownedRow(_ id: UUID, in context: ModelContext) throws -> SharedFridgeRecord {
        guard let row = try fridgeRow(id, in: context), row.status == .active else { throw FridgeStoreError.fridgeNotFound }
        guard row.role == .owner else { throw SharedStoreError.ownerOnly }
        return row
    }

    private func deleteFoodRows(_ id: UUID, oldFridge: SharedFridgeRecord, in context: ModelContext) throws -> [CKRecord.ID] {
        var ids: [CKRecord.ID] = []
        for row in try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })) {
            context.delete(row)
            ids.append(inventoryID(id, oldFridge))
        }
        for op in try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.foodID == id })) {
            context.delete(op)
            ids.append(inventoryID(op.id, oldFridge))
        }
        return ids
    }

    private func structureID(_ row: SharedFridgeRecord) -> CKRecord.ID { structureID(row.id, row) }

    private func structureID(_ recordName: UUID, _ fridge: SharedFridgeRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName.uuidString,
                    zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: fridge.zoneOwnerName))
    }

    private func inventoryID(_ recordName: UUID, _ fridge: SharedFridgeRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName.uuidString,
                    zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: fridge.zoneOwnerName))
    }

    private func report(saves: [CKRecord.ID] = [], deletes: [CKRecord.ID] = [], scope: SharedDatabaseScope) {
        guard !saves.isEmpty || !deletes.isEmpty else { return }
        onLocalChange?(Change(saves: saves, deletes: deletes, scope: scope))
    }
}

extension SharedFridgeRole {
    var scope: SharedDatabaseScope { self == .owner ? .private : .shared }
}

private extension FoodItem {
    func withQuantity(_ quantity: Decimal) -> FoodItem {
        var copy = self
        copy.quantity = quantity
        return copy
    }
}
