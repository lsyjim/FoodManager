import Foundation
import SwiftData

/// SwiftData row for one food record. Images are never stored: `categoryID` points at a bundled illustration.
/// `quantity` is persisted as a POSIX decimal string so values like 1.5 round-trip exactly.
@Model
final class FoodItemRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var categoryID: String
    var quantityText: String
    var unit: String
    var storedAt: Date
    var expirationDate: Date?
    var storageReminderDays: Int?
    var fridgeID: UUID
    var compartmentID: UUID
    var createdAt: Date
    var updatedAt: Date
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
}

final class SwiftDataFoodStore: FoodStore {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func activeItems(fridgeID: UUID) throws -> [FoodItem] {
        let descriptor = FetchDescriptor<FoodItemRecord>(
            predicate: #Predicate { $0.fridgeID == fridgeID && $0.consumedAt == nil },
            sortBy: [SortDescriptor(\.storedAt), SortDescriptor(\.name)])
        return try context.fetch(descriptor).map(\.item)
    }

    func consumedItems(fridgeID: UUID) throws -> [FoodItem] {
        let descriptor = FetchDescriptor<FoodItemRecord>(
            predicate: #Predicate { $0.fridgeID == fridgeID && $0.consumedAt != nil })
        return try context.fetch(descriptor).map(\.item)
    }

    func upsert(_ item: FoodItem) throws {
        if let record = try record(id: item.id) {
            record.apply(item)
        } else {
            context.insert(FoodItemRecord(item))
        }
        try saveOrRollback()
    }

    func delete(id: UUID) throws {
        guard let record = try record(id: id) else { throw FoodStoreError.notFound }
        context.delete(record)
        try saveOrRollback()
    }

    private func record(id: UUID) throws -> FoodItemRecord? {
        try context.fetch(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
