import Foundation
import SwiftData
import os

enum FridgeStoreError: Error, Equatable {
    case fridgeNotFound
    case invalidLayout([LayoutValidationError])
}

/// Persistence boundary for fridges. UI and editor depend on this protocol, not on SwiftData.
protocol FridgeStore: AnyObject {
    /// Returns the user's fridge, creating the default one on first launch.
    func loadOrCreateFridge() throws -> Fridge
    /// Validates and atomically replaces the fridge's name/template/layout.
    func saveLayout(_ fridge: Fridge) throws
    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws
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

    func loadOrCreateFridge() throws -> Fridge {
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
        return fridge
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

    /// Maps a record to the domain model. A corrupt or invalid stored layout falls back to the
    /// template default in memory (not written back), so the app stays usable and the original bytes survive.
    private func fridge(from record: FridgeRecord) -> Fridge {
        let template = FridgeTemplateCatalog.template(id: record.templateID)
        var fridge = Fridge(id: record.id, name: record.name, templateID: template.id,
                            lastDoorState: DoorState(rawValue: record.lastDoorStateRaw) ?? .closed,
                            cabinetCompartments: [], doorCompartments: [])
        let layout = try? StoredLayout.decode(record.layoutData)
        if let layout {
            fridge.cabinetCompartments = layout.cabinetCompartments
            fridge.doorCompartments = layout.doorCompartments
        }
        if layout == nil || !FridgeLayoutEngine.validate(fridge).isEmpty {
            logger.error("Stored layout for fridge \(record.id) is invalid; using template default")
            let fallback = FridgeFactory.makeDefault(template: template, name: record.name)
            fridge.cabinetCompartments = fallback.cabinetCompartments
            fridge.doorCompartments = fallback.doorCompartments
        }
        return fridge
    }
}
