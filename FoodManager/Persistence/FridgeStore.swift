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
}

extension FridgeStore {
    func loadOrCreateFridge() throws -> Fridge { try load().fridge }
}

final class SwiftDataFridgeStore: FridgeStore {
    private let context: ModelContext
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "FridgeStore")

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// `url == nil && inMemory == false` uses the default app-support store.
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        // Phase 2 adds FoodItemRecord as a new, independent entity. Adding an entity is a lightweight,
        // non-destructive migration: existing FridgeRecord rows are kept as-is.
        let schema = Schema([FridgeRecord.self, FoodItemRecord.self])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func load() throws -> FridgeLoadResult {
        var descriptor = FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            return fridge(from: record)
        }
        let fridge = FridgeFactory.makeDefault()
        let record = FridgeRecord(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                  lastDoorStateRaw: fridge.lastDoorState.rawValue,
                                  layoutData: try StoredLayout.encode(fridge))
        context.insert(record)
        try saveOrRollback()
        return FridgeLoadResult(fridge: fridge, recovery: .none)
    }

    func saveLayout(_ fridge: Fridge) throws {
        let errors = FridgeLayoutEngine.validate(fridge)
        guard errors.isEmpty else { throw FridgeStoreError.invalidLayout(errors) }
        let data = try StoredLayout.encode(fridge)
        let record = try fetchRecord(id: fridge.id)
        record.name = fridge.name
        record.templateID = fridge.templateID
        record.layoutData = data
        record.updatedAt = .now
        try saveOrRollback()
    }

    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws {
        let record = try fetchRecord(id: fridgeID)
        record.lastDoorStateRaw = state.rawValue
        try saveOrRollback()
    }

    func loadAll() throws -> [FridgeLoadResult] {
        let records = try context.fetch(FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)]))
        guard !records.isEmpty else { return [try load()] } // first launch: default fridge
        return records.map(fridge(from:))
    }

    func create(_ fridge: Fridge) throws {
        let errors = FridgeLayoutEngine.validate(fridge)
        guard errors.isEmpty else { throw FridgeStoreError.invalidLayout(errors) }
        context.insert(FridgeRecord(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                    lastDoorStateRaw: fridge.lastDoorState.rawValue, layoutData: try StoredLayout.encode(fridge)))
        try saveOrRollback()
    }

    func rename(fridgeID: UUID, to name: String) throws {
        let record = try fetchRecord(id: fridgeID)
        record.name = name
        record.updatedAt = .now
        try saveOrRollback()
    }

    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws {
        let record = try fetchRecord(id: fridgeID)
        _ = try fetchRecord(id: historyDestination)
        let food = try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let active = food.filter { $0.consumedAt == nil }.count
        guard active == 0 else { throw FridgeStoreError.fridgeHasActiveFood(active) }
        // History is kept: it moves to the remaining fridge (its old compartment IDs no longer exist there,
        // so restoring asks the user where to put it — nothing is placed silently).
        for item in food { item.fridgeID = historyDestination }
        context.delete(record)
        try saveOrRollback()
    }

    // MARK: - Private

    private func fetchRecord(id: UUID) throws -> FridgeRecord {
        let descriptor = FetchDescriptor<FridgeRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw FridgeStoreError.fridgeNotFound }
        return record
    }

    private func saveOrRollback() throws {
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
