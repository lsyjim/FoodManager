import Foundation
import SwiftData
import os

// Local cache of shared refrigerators (Phase 5D). A separate SwiftData store that is never mirrored by SwiftData
// (`cloudKitDatabase: .none`): `SharedSyncEngine` alone syncs it with the custom CloudKit zones — the owner's in the
// private database, a participant's in the shared database. Personal fridges stay in the main store and its
// automatic SwiftData mirroring; no record is ever managed by both pipelines.
//
// `systemFields` hold each row's archived CloudKit system fields (change tag), so uploads modify the server record
// instead of conflicting with it.

@Model
final class SharedFridgeRecord {
    var id: UUID = UUID()
    /// `SharedFridgeRole`.
    var roleRaw: String = SharedFridgeRole.owner.rawValue
    /// `SharedFridgeStatus`.
    var statusRaw: String = SharedFridgeStatus.active.rawValue
    /// Zone owner (`CKCurrentUserDefaultName` for the owner's own fridges).
    var zoneOwnerName: String = ""
    var isShared: Bool = false
    /// Owner only: the invitation link (inventory share) and the read-only structure share. Never logged.
    var inventoryShareURL: String?
    var structureShareURL: String?
    var name: String = ""
    var templateID: String = ""
    var layoutData: Data = Data()
    /// This device's door state; never uploaded.
    var lastDoorStateRaw: String = "closed"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var systemFields: Data?

    init(id: UUID, role: SharedFridgeRole, zoneOwnerName: String) {
        self.id = id
        roleRaw = role.rawValue
        self.zoneOwnerName = zoneOwnerName
    }

    var role: SharedFridgeRole { SharedFridgeRole(rawValue: roleRaw) ?? .participant }
    var status: SharedFridgeStatus { SharedFridgeStatus(rawValue: statusRaw) ?? .unavailable }

    var ownership: SharedFridgeOwnership {
        switch (status, role) {
        case (.unavailable, _): return .unavailableOrRevoked
        case (.pendingApproval, _): return .pendingInvitation
        case (.active, .owner): return isShared ? .sharedOwned : .personalOwned
        case (.active, .participant): return .sharedParticipant
        }
    }
}

enum SharedFridgeRole: String {
    case owner
    case participant
}

enum SharedFridgeStatus: String {
    case active
    case pendingApproval
    case unavailable
}

@Model
final class SharedFoodRecord {
    var id: UUID = UUID()
    var fridgeID: UUID = UUID()
    var compartmentID: UUID = UUID()
    var name: String = ""
    var categoryID: String = ""
    /// Base of the operation ledger (`QuantityLedger`); POSIX decimal text, may be negative after compaction.
    var baseQuantityText: String = "0"
    /// JSON `[UUID]` of ops already folded into the base.
    var foldedOpIDsData: Data = Data()
    var unit: String = ""
    var storedAt: Date = Date.now
    var expirationDate: Date?
    var storageReminderDays: Int?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var consumedAt: Date?
    var systemFields: Data?

    init(id: UUID, fridgeID: UUID) {
        self.id = id
        self.fridgeID = fridgeID
    }

    var baseQuantity: Decimal {
        get { Decimal(string: baseQuantityText, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
        set { baseQuantityText = (newValue as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX")) }
    }

    var foldedOpIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: foldedOpIDsData)) ?? [] }
        set { foldedOpIDsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
final class SharedQuantityOpRecord {
    var id: UUID = UUID()
    var foodID: UUID = UUID()
    var fridgeID: UUID = UUID()
    var deltaText: String = "0"
    var createdAt: Date = Date.now
    var systemFields: Data?

    init(_ op: QuantityOp, fridgeID: UUID) {
        id = op.id
        foodID = op.foodID
        self.fridgeID = fridgeID
        deltaText = (op.delta as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX"))
        createdAt = op.createdAt
    }

    var op: QuantityOp {
        QuantityOp(id: id, foodID: foodID, delta: Decimal(string: deltaText, locale: Locale(identifier: "en_US_POSIX")) ?? 0,
                   createdAt: createdAt)
    }
}

@Model
final class SharedMagnetRecord {
    var id: UUID = UUID()
    var fridgeID: UUID = UUID()
    var sourceRaw: String = "builtIn"
    var builtInAssetID: String?
    var styleRaw: String?
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.3
    var height: Double = 0.3
    var rotation: Double = 0
    var zIndex: Int = 0
    /// Photo magnets: the image ID used by `MagnetImageStore` (several magnets may show the same photo).
    var imageID: UUID?
    /// Photo bytes (uploaded as a CKAsset).
    @Attribute(.externalStorage) var imageData: Data?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var systemFields: Data?

    init(id: UUID, fridgeID: UUID) {
        self.id = id
        self.fridgeID = fridgeID
    }
}

/// `CKSyncEngine.State.Serialization` per database scope.
@Model
final class SharedSyncStateRecord {
    var scopeRaw: String = ""
    var data: Data = Data()

    init(scopeRaw: String, data: Data) {
        self.scopeRaw = scopeRaw
        self.data = data
    }
}

/// Opens and edits `Shared.store`. A fresh context per operation, like `SwiftDataFridgeStore`.
final class SharedStore {
    let container: ModelContainer
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "SharedStore")

    init(container: ModelContainer) {
        self.container = container
    }

    static let schema = Schema([SharedFridgeRecord.self, SharedFoodRecord.self, SharedQuantityOpRecord.self,
                                SharedMagnetRecord.self, SharedSyncStateRecord.self])

    /// Next to the main store (App Group container), as a separate file.
    static var defaultURL: URL {
        SwiftDataFridgeStore.defaultStoreURL.deletingLastPathComponent().appendingPathComponent("Shared.store")
    }

    /// Never SwiftData-mirrored: with the iCloud entitlement present SwiftData would otherwise sync it on its own.
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("Shared", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("Shared", schema: schema, url: url ?? defaultURL, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    // MARK: Reads

    func fridges() throws -> [SharedFridgeSummary] {
        try makeContext().fetch(FetchDescriptor<SharedFridgeRecord>(sortBy: [SortDescriptor(\.createdAt)])).map {
            SharedFridgeSummary(id: $0.id, name: $0.name, role: $0.role, ownership: $0.ownership)
        }
    }

    func ownerships() throws -> [SharedFridgeOwnership] {
        try fridges().map(\.ownership)
    }

    /// Current quantity of a shared food: its base plus every op not folded yet.
    func quantity(foodID: UUID) throws -> Decimal? {
        let context = makeContext()
        guard let food = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == foodID })).first else {
            return nil
        }
        let ops = try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.foodID == foodID }))
        return QuantityLedger.quantity(base: food.baseQuantity, folded: Set(food.foldedOpIDs), ops: ops.map(\.op))
    }

    // MARK: Writes

    /// Records a quantity change as a new op (the caller queues its upload). Returns the op ID.
    @discardableResult
    func recordQuantityChange(foodID: UUID, delta: Decimal, at date: Date = .now) throws -> UUID {
        guard QuantityLedger.isValidDelta(delta) else { throw SharedStoreError.invalidQuantity }
        let context = makeContext()
        guard let food = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == foodID })).first else {
            throw SharedStoreError.notFound
        }
        let op = QuantityOp(id: UUID(), foodID: foodID, delta: delta, createdAt: date)
        context.insert(SharedQuantityOpRecord(op, fridgeID: food.fridgeID))
        try context.save()
        return op.id
    }

    func syncState(scope: String) throws -> Data? {
        try makeContext().fetch(FetchDescriptor<SharedSyncStateRecord>(predicate: #Predicate { $0.scopeRaw == scope })).first?.data
    }

    func saveSyncState(_ data: Data?, scope: String) throws {
        let context = makeContext()
        let rows = try context.fetch(FetchDescriptor<SharedSyncStateRecord>(predicate: #Predicate { $0.scopeRaw == scope }))
        rows.forEach(context.delete)
        if let data { context.insert(SharedSyncStateRecord(scopeRaw: scope, data: data)) }
        try context.save()
    }

    /// Revocation cleanup: drops every inventory, structure and magnet row of the fridge. With `keepPlaceholder`
    /// the fridge row stays (name only) marked unavailable, so the selector can say 共享無法存取.
    func purgeFridge(_ fridgeID: UUID, keepPlaceholder: Bool) throws {
        let context = makeContext()
        try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.fridgeID == fridgeID })).forEach(context.delete)
        try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.fridgeID == fridgeID })).forEach(context.delete)
        try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID })).forEach(context.delete)
        for fridge in try context.fetch(FetchDescriptor<SharedFridgeRecord>(predicate: #Predicate { $0.id == fridgeID })) {
            if keepPlaceholder {
                fridge.statusRaw = SharedFridgeStatus.unavailable.rawValue
                fridge.layoutData = Data()
                fridge.isShared = false
                fridge.systemFields = nil
            } else {
                context.delete(fridge)
            }
        }
        try context.save()
        logger.info("Purged a shared fridge (placeholder kept: \(keepPlaceholder))")
    }

    /// Account sign-out / switch: another account's shared data must not stay readable on this device.
    func purgeAll(role: SharedFridgeRole) throws {
        for fridge in try fridges() where fridge.role == role {
            try purgeFridge(fridge.id, keepPlaceholder: false)
        }
    }
}

/// Value copy of a shared fridge row (models never leave their context).
struct SharedFridgeSummary: Equatable {
    let id: UUID
    let name: String
    let role: SharedFridgeRole
    let ownership: SharedFridgeOwnership
}

enum SharedStoreError: Error, Equatable {
    case notFound
    case invalidQuantity
    /// Only the owner may change a shared fridge's name, compartments or magnets.
    case ownerOnly
    case alreadyShared
    /// A photo magnet's bytes aren't on this device (yet).
    case photoMissing

    var message: String {
        switch self {
        case .ownerOnly: return "只有冰箱主人可以修改冰箱名稱、隔層與磁鐵。"
        case .photoMissing: return "有磁鐵照片還沒下載完成，請稍後再試。"
        case .alreadyShared: return "這台冰箱已經共享。"
        case .notFound, .invalidQuantity: return "無法儲存，請再試一次。"
        }
    }
}
