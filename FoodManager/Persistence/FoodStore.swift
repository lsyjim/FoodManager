import Foundation
import SwiftData

/// SwiftData row for one food record. Images are never stored: `categoryID` points at a bundled illustration.
/// `quantity` is persisted as a POSIX decimal string so values like 1.5 round-trip exactly.
/// CloudKit-compatible: defaults everywhere, no unique constraint (see `FridgeRecord`).
@Model
final class FoodItemRecord {
    var id: UUID = UUID()
    var name: String = ""
    var categoryID: String = ""
    var quantityText: String = "1"
    var unit: String = ""
    var storedAt: Date = Date.now
    var expirationDate: Date?
    var storageReminderDays: Int?
    var fridgeID: UUID = UUID()
    var compartmentID: UUID = UUID()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var consumedAt: Date?

    init(_ item: FoodItem) {
        id = item.id
        name = item.name
        categoryID = item.categoryID
        quantityText = ""
        unit = item.unit
        storedAt = item.storedAt
        fridgeID = item.fridgeID
        compartmentID = item.compartmentID
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        apply(item)
    }

    func apply(_ item: FoodItem) {
        name = item.name
        categoryID = item.categoryID
        quantityText = (item.quantity as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX"))
        unit = item.unit
        storedAt = item.storedAt
        expirationDate = item.expirationDate
        storageReminderDays = item.storageReminderDays
        fridgeID = item.fridgeID
        compartmentID = item.compartmentID
        updatedAt = item.updatedAt
        consumedAt = item.consumedAt
    }

    var item: FoodItem {
        FoodItem(id: id, name: name, categoryID: categoryID,
                 quantity: Decimal(string: quantityText, locale: Locale(identifier: "en_US_POSIX")) ?? 0,
                 unit: unit, storedAt: storedAt, expirationDate: expirationDate,
                 storageReminderDays: storageReminderDays, fridgeID: fridgeID, compartmentID: compartmentID,
                 createdAt: createdAt, updatedAt: updatedAt, consumedAt: consumedAt)
    }
}

enum FoodStoreError: Error, Equatable {
    case notFound
}

/// Raw persistence for food records. Business rules live in `FoodInventoryService`.
protocol FoodStore: AnyObject {
    func activeItems(fridgeID: UUID) throws -> [FoodItem]
    /// Records marked as consumed (history). Same table, no duplicated rows.
    func consumedItems(fridgeID: UUID) throws -> [FoodItem]
    func upsert(_ item: FoodItem) throws
    func delete(id: UUID) throws
    /// Active food whose fridge isn't among `knownFridgeIDs` (see `SyncReconciler`).
    func unplacedActiveItems(knownFridgeIDs: Set<UUID>) throws -> [FoodItem]
}

final class SwiftDataFoodStore: FoodStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// A fresh context per operation, so changes imported from iCloud are always seen.
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func activeItems(fridgeID: UUID) throws -> [FoodItem] {
        // Duplicate rows of one record are collapsed before filtering, so the newest state (e.g. consumed on
        // another device) decides whether it is active.
        try items(fridgeID: fridgeID).filter { $0.consumedAt == nil }
    }

    func consumedItems(fridgeID: UUID) throws -> [FoodItem] {
        try items(fridgeID: fridgeID).filter { $0.consumedAt != nil }
    }

    private func items(fridgeID: UUID) throws -> [FoodItem] {
        let descriptor = FetchDescriptor<FoodItemRecord>(
            predicate: #Predicate { $0.fridgeID == fridgeID },
            sortBy: [SortDescriptor(\.storedAt), SortDescriptor(\.name)])
        return SyncedRecords.unique(try makeContext().fetch(descriptor)).map(\.item)
    }

    /// Food whose fridge isn't (yet) on this device — e.g. its fridge record hasn't arrived from iCloud, or it was
    /// deleted on another device. Never reassigned automatically.
    func unplacedActiveItems(knownFridgeIDs: Set<UUID>) throws -> [FoodItem] {
        return SyncedRecords.unique(try makeContext().fetch(FetchDescriptor<FoodItemRecord>()))
            .filter { $0.consumedAt == nil && !knownFridgeIDs.contains($0.fridgeID) }
            .map(\.item)
    }

    func upsert(_ item: FoodItem) throws {
        let context = makeContext()
        let records = try records(id: item.id, in: context)
        if records.isEmpty {
            context.insert(FoodItemRecord(item))
        } else {
            for record in records { record.apply(item) }
        }
        try save(context)
    }

    func delete(id: UUID) throws {
        let context = makeContext()
        let records = try records(id: id, in: context)
        guard !records.isEmpty else { throw FoodStoreError.notFound }
        for record in records { context.delete(record) }
        try save(context)
    }

    private func records(id: UUID, in context: ModelContext) throws -> [FoodItemRecord] {
        try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.id == id }))
    }

    private func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
