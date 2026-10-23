import Foundation
import SwiftData

/// Fridges and food as backup DTOs. Kept separate from `FridgeStore` / `FoodStore`, which work one record at a time.
/// Everything kept in the database.
struct StoredInventory: Equatable {
    var fridges: [BackupFridge]
    var foods: [BackupFood]
    var magnets: [FridgeMagnet] = []
    /// Synced magnet photo bytes by image ID (a restore stores them so they sync too).
    var images: [UUID: Data] = [:]
}

protocol InventoryBackupStore: AnyObject {
    func readInventory() throws -> StoredInventory
    /// Replaces every fridge, food and magnet record in ONE save: either all of it is committed or none of it.
    func replaceInventory(_ inventory: StoredInventory) throws
}

/// Preferences kept in UserDefaults (not part of the database).
protocol PreferencesBackupStore: AnyObject {
    func readPreferences() -> BackupPreferences
    func writePreferences(_ preferences: BackupPreferences) throws
}

enum PreferencesBackupError: Error {
    case encodingFailed
    case notPersisted
}

final class SwiftDataInventoryBackupStore: InventoryBackupStore {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func readInventory() throws -> StoredInventory {
        // A fresh context every time, so nothing cached from an earlier read or a failed save leaks in.
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)]))
        let createdAt = Dictionary(SyncedRecords.unique(records).map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        // Same mapping (and in-memory layout recovery) the app itself uses; never writes.
        let fridges = try SwiftDataFridgeStore(container: container).loadExisting().map {
            BackupFridge($0.fridge, createdAt: createdAt[$0.fridge.id] ?? .now)
        }
        let foods = SyncedRecords.unique(try context.fetch(FetchDescriptor<FoodItemRecord>())).map { BackupFood($0.item) }
        let magnets = SyncedRecords.unique(try context.fetch(FetchDescriptor<MagnetRecord>())).map(\.magnet)
        var images: [UUID: Data] = [:]
        for record in try context.fetch(FetchDescriptor<MagnetImageRecord>()) where images[record.id] == nil {
            if let data = record.data { images[record.id] = data }
        }
        return StoredInventory(fridges: fridges, foods: foods, magnets: magnets, images: images)
    }

    func replaceInventory(_ inventory: StoredInventory) throws {
        let fridges = inventory.fridges
        let foods = inventory.foods
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let now = Date()

        // Rows are updated in place when their ID is kept (IDs are unique, so delete + insert of the same ID
        // in one save is avoided), deleted when absent from the backup and inserted when new.
        // Every row of an ID is updated (or deleted): CloudKit can leave more than one row per app ID.
        let existingFridges = Dictionary(grouping: try context.fetch(FetchDescriptor<FridgeRecord>()), by: \.id)
        let keptFridges = Set(fridges.map(\.id))
        for (id, records) in existingFridges where !keptFridges.contains(id) { records.forEach(context.delete) }
        for backup in fridges {
            let domain = backup.fridge
            let layout = try StoredLayout.encode(domain)
            if let records = existingFridges[backup.id] {
                for record in records {
                    record.name = domain.name
                    record.templateID = domain.templateID
                    record.lastDoorStateRaw = domain.lastDoorState.rawValue
                    record.layoutData = layout
                    record.createdAt = backup.createdAt
                    record.updatedAt = now
                }
            } else {
                context.insert(FridgeRecord(id: domain.id, name: domain.name, templateID: domain.templateID,
                                            lastDoorStateRaw: domain.lastDoorState.rawValue, layoutData: layout,
                                            createdAt: backup.createdAt))
            }
        }

        let existingFoods = Dictionary(grouping: try context.fetch(FetchDescriptor<FoodItemRecord>()), by: \.id)
        let keptFoods = Set(foods.map(\.id))
        for (id, records) in existingFoods where !keptFoods.contains(id) { records.forEach(context.delete) }
        for backup in foods {
            let item = backup.item
            if let records = existingFoods[backup.id] {
                for record in records {
                    record.apply(item)
                    record.createdAt = item.createdAt
                    record.updatedAt = item.updatedAt
                }
            } else {
                context.insert(FoodItemRecord(item))
            }
        }

        let existingMagnets = Dictionary(grouping: try context.fetch(FetchDescriptor<MagnetRecord>()), by: \.id)
        let keptMagnets = Set(inventory.magnets.map(\.id))
        for (id, records) in existingMagnets where !keptMagnets.contains(id) { records.forEach(context.delete) }
        for magnet in inventory.magnets {
            if let records = existingMagnets[magnet.id] {
                for record in records { record.apply(magnet) }
            } else {
                context.insert(MagnetRecord(magnet))
            }
        }

        // Photos: exactly the restored set (a full replacement also replaces the synced photos).
        let existingImages = Dictionary(grouping: try context.fetch(FetchDescriptor<MagnetImageRecord>()), by: \.id)
        for (id, records) in existingImages where inventory.images[id] == nil { records.forEach(context.delete) }
        for (id, data) in inventory.images {
            if let records = existingImages[id] {
                for record in records where record.data != data { record.data = data }
            } else {
                context.insert(MagnetImageRecord(id: id, data: data))
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

/// Reads and writes the preferences through the same keys the app uses. Favorite category IDs are kept raw,
/// so IDs from a newer build survive a restore (the picker simply ignores IDs it doesn't know).
final class UserDefaultsPreferencesBackupStore: PreferencesBackupStore {
    private let defaults: UserDefaults
    private let selection: FridgeSelectionStore

    init(defaults: UserDefaults = .standard, selection: FridgeSelectionStore) {
        self.defaults = defaults
        self.selection = selection
    }

    func readPreferences() -> BackupPreferences {
        BackupPreferences(favoriteCategoryIDs: defaults.stringArray(forKey: UserDefaultsFavoriteCategoryStore.key) ?? [],
                          favoriteFoods: UserDefaultsFavoriteFoodStore(defaults: defaults).load().templates,
                          notifications: UserDefaultsNotificationPreferencesStore(defaults: defaults).load(),
                          selectedFridgeID: selection.selectedFridgeID)
    }

    func writePreferences(_ preferences: BackupPreferences) throws {
        let encoder = JSONEncoder()
        guard let favoriteFoods = try? encoder.encode(preferences.favoriteFoods),
              let notifications = try? encoder.encode(preferences.notifications) else {
            throw PreferencesBackupError.encodingFailed
        }
        defaults.set(preferences.favoriteCategoryIDs, forKey: UserDefaultsFavoriteCategoryStore.key)
        defaults.set(favoriteFoods, forKey: UserDefaultsFavoriteFoodStore.key)
        defaults.set(notifications, forKey: UserDefaultsNotificationPreferencesStore.key)
        selection.selectedFridgeID = preferences.selectedFridgeID
        // UserDefaults never reports write errors, so read everything back.
        guard readPreferences() == preferences else { throw PreferencesBackupError.notPersisted }
    }
}
