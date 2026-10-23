import Foundation
import SwiftData
import os

enum FridgeStoreError: Error, Equatable {
    case fridgeNotFound
    case invalidLayout([LayoutValidationError])
    /// The fridge still holds active food; it must be moved or consumed first.
    case fridgeHasActiveFood(Int)
}

/// Persistence boundary for fridges. UI and editor depend on this protocol, not on SwiftData.
protocol FridgeStore: AnyObject {
    /// Returns the user's fridge (creating the default one on first launch) and whether its stored
    /// layout had to be recovered. Loading never rewrites stored layout bytes.
    func load() throws -> FridgeLoadResult
    /// Validates and atomically replaces the fridge's name/template/layout.
    func saveLayout(_ fridge: Fridge) throws
    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws
    /// Every fridge, oldest first (creates the default fridge when there is none). Never rewrites stored data.
    func loadAll() throws -> [FridgeLoadResult]
    /// Inserts a new fridge with a validated layout.
    func create(_ fridge: Fridge) throws
    func rename(fridgeID: UUID, to name: String) throws
    /// Deletes an empty fridge and, in the same save, hands its consumed-food history to `historyDestination`.
    /// Throws `fridgeHasActiveFood` (and changes nothing) if active food still belongs to it.
    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws
    /// Moves everything of `sourceID` (active food into `compartmentID` of the target) and deletes it. One save.
    func mergeFridge(_ sourceID: UUID, into targetID: UUID, compartmentID: UUID) throws
}

extension FridgeStore {
    func loadOrCreateFridge() throws -> Fridge { try load().fridge }
}

final class SwiftDataFridgeStore: FridgeStore {
    let container: ModelContainer
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "FridgeStore")

    init(container: ModelContainer) {
        self.container = container
    }

    static let schema = Schema([FridgeRecord.self, FoodItemRecord.self, MagnetRecord.self, MagnetImageRecord.self])

    /// `url == nil && inMemory == false` uses the default app-support store (in the App Group container).
    /// Always local: `cloudKitDatabase: .none` is explicit, because with the iCloud entitlement present SwiftData would
    /// otherwise mirror the store to CloudKit on its own. Personal data reaches iCloud only through a manual backup.
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        // Schema history (all migrations are lightweight and keep every row):
        // - Phase 2 adds FoodItemRecord, Phase 4.3 adds MagnetRecord (new entities).
        // - Phase 4.4 removes the unique constraints, adds attribute defaults and adds MagnetImageRecord.
        // - Phase 5E stops CloudKit mirroring; stores mirrored before open unchanged without it.
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Where the default store lives, without opening it (used for the pre-sync file copy).
    static var defaultStoreURL: URL {
        ModelConfiguration(schema: schema, cloudKitDatabase: .none).url
    }

    /// A fresh context per operation: nothing cached can hide changes that arrived from iCloud in the meantime.
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func load() throws -> FridgeLoadResult {
        try loadAll()[0]
    }

    func saveLayout(_ fridge: Fridge) throws {
        let errors = FridgeLayoutEngine.validate(fridge)
        guard errors.isEmpty else { throw FridgeStoreError.invalidLayout(errors) }
        let data = try StoredLayout.encode(fridge)
        let context = makeContext()
        for record in try fetchRecords(id: fridge.id, in: context) {
            record.name = fridge.name
            record.templateID = fridge.templateID
            record.layoutData = data
            record.updatedAt = .now
        }
        try save(context)
    }

    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws {
        let context = makeContext()
        for record in try fetchRecords(id: fridgeID, in: context) { record.lastDoorStateRaw = state.rawValue }
        try save(context)
    }

    func loadAll() throws -> [FridgeLoadResult] {
        let context = makeContext()
        let records = SyncedRecords.unique(try context.fetch(FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)])))
        guard records.isEmpty else { return records.map(fridge(from:)) }
        // First launch: one default fridge. Its IDs are fixed, so two new devices that both create it end up with
        // the same logical fridge after syncing instead of two "我的冰箱" (see `SyncReconciler`).
        let fridge = FridgeFactory.makeFirstLaunchDefault()
        context.insert(FridgeRecord(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                    lastDoorStateRaw: fridge.lastDoorState.rawValue,
                                    layoutData: try StoredLayout.encode(fridge)))
        try save(context)
        return [FridgeLoadResult(fridge: fridge, recovery: .none)]
    }

    /// Stored fridges only (never creates the default one). Used when shared fridges exist.
    func loadExisting() throws -> [FridgeLoadResult] {
        SyncedRecords.unique(try makeContext().fetch(FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)])))
            .map(fridge(from:))
    }

    /// IDs of the stored fridges (cheap; no layout decoding).
    func existingIDs() throws -> Set<UUID> {
        Set(try makeContext().fetch(FetchDescriptor<FridgeRecord>()).map(\.id))
    }

    /// After a fridge became shared (its copy in the shared store is confirmed by the server): removes every
    /// personal row of it — fridge, food and history, magnets and photos only it used — in one save.
    func removeFridgeAfterSharing(_ fridgeID: UUID) throws {
        let context = makeContext()
        let records = try fetchRecords(id: fridgeID, in: context)
        try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.fridgeID == fridgeID })).forEach(context.delete)
        try MagnetRecordCleanup.deleteMagnets(ofFridge: fridgeID, in: context)
        for record in records { context.delete(record) }
        try save(context)
    }

    func create(_ fridge: Fridge) throws {
        let errors = FridgeLayoutEngine.validate(fridge)
        guard errors.isEmpty else { throw FridgeStoreError.invalidLayout(errors) }
        let context = makeContext()
        context.insert(FridgeRecord(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                    lastDoorStateRaw: fridge.lastDoorState.rawValue, layoutData: try StoredLayout.encode(fridge)))
        try save(context)
    }

    func rename(fridgeID: UUID, to name: String) throws {
        let context = makeContext()
        for record in try fetchRecords(id: fridgeID, in: context) {
            record.name = name
            record.updatedAt = .now
        }
        try save(context)
    }

    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws {
        let context = makeContext()
        let records = try fetchRecords(id: fridgeID, in: context)
        _ = try fetchRecords(id: historyDestination, in: context)
        let food = try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let active = Set(food.filter { $0.consumedAt == nil }.map(\.id)).count
        guard active == 0 else { throw FridgeStoreError.fridgeHasActiveFood(active) }
        // History is kept: it moves to the remaining fridge (its old compartment IDs no longer exist there,
        // so restoring asks the user where to put it — nothing is placed silently).
        for item in food { item.fridgeID = historyDestination }
        // Its magnets go in the same save, with photos only they used.
        try MagnetRecordCleanup.deleteMagnets(ofFridge: fridgeID, in: context)
        for record in records { context.delete(record) }
        try save(context)
    }

    /// Resolves a fridge-count conflict without losing anything: every food record and magnet of `sourceID`
    /// moves to `targetID` (active food into `compartmentID`, which must belong to the target), then the source
    /// fridge is deleted. One save.
    func mergeFridge(_ sourceID: UUID, into targetID: UUID, compartmentID: UUID) throws {
        let context = makeContext()
        let sources = try fetchRecords(id: sourceID, in: context)
        guard let target = SyncedRecords.unique(try fetchRecords(id: targetID, in: context)).first, sourceID != targetID else {
            throw FridgeStoreError.fridgeNotFound
        }
        guard fridge(from: target).fridge.allCompartments.contains(where: { $0.id == compartmentID }) else {
            throw FridgeStoreError.fridgeNotFound
        }
        let now = Date()
        for item in try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.fridgeID == sourceID })) {
            item.fridgeID = targetID
            if item.consumedAt == nil { item.compartmentID = compartmentID }
            item.updatedAt = now
        }
        let targetTop = (try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == targetID }))
            .map(\.zIndex).max() ?? -1) + 1
        for magnet in try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == sourceID })) {
            magnet.fridgeID = targetID
            magnet.zIndex += targetTop
            magnet.updatedAt = now
        }
        for record in sources { context.delete(record) }
        try save(context)
    }

    // MARK: - Private

    /// Every row carrying this app ID (normally one; more if two devices stored the same record before syncing).
    private func fetchRecords(id: UUID, in context: ModelContext) throws -> [FridgeRecord] {
        let records = try context.fetch(FetchDescriptor<FridgeRecord>(predicate: #Predicate { $0.id == id }))
        guard !records.isEmpty else { throw FridgeStoreError.fridgeNotFound }
        return records
    }

    private func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Maps a record to the domain model without ever writing back:
    /// - valid layout → used as-is;
    /// - decodable but invalid → repaired in memory, keeping compartment IDs (food stays attached);
    /// - undecodable (or unrepairable) → template default with IDs derived from the fridge ID, so the
    ///   fallback is identical on every launch. The original bytes stay in the store until the user confirms.
    private func fridge(from record: FridgeRecord) -> FridgeLoadResult {
        let template = FridgeTemplateCatalog.template(id: record.templateID)
        var fridge = Fridge(id: record.id, name: record.name, templateID: template.id,
                            lastDoorState: DoorState(rawValue: record.lastDoorStateRaw) ?? .closed,
                            cabinetCompartments: [], doorCompartments: [])
        if let layout = try? StoredLayout.decode(record.layoutData) {
            fridge.cabinetCompartments = layout.cabinetCompartments
            fridge.doorCompartments = layout.doorCompartments
            if FridgeLayoutEngine.validate(fridge).isEmpty {
                return FridgeLoadResult(fridge: fridge, recovery: .none)
            }
            if let repaired = FridgeLayoutRepair.repair(fridge) {
                logger.error("Stored layout for a fridge was invalid; repaired in memory keeping compartment IDs")
                return FridgeLoadResult(fridge: repaired, recovery: .repaired)
            }
        }
        logger.error("Stored layout for a fridge could not be decoded or repaired; showing deterministic default")
        let fallback = FridgeFactory.makeDefault(template: template, name: record.name, idSeed: record.id)
        fridge.cabinetCompartments = fallback.cabinetCompartments
        fridge.doorCompartments = fallback.doorCompartments
        return FridgeLoadResult(fridge: fridge, recovery: .replacedWithDefault)
    }
}
