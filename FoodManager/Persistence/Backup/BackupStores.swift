import Foundation
import SwiftData

/// Fridges and food as backup DTOs. Kept separate from `FridgeStore` / `FoodStore`, which work one record at a time.
protocol InventoryBackupStore: AnyObject {
    func readInventory() throws -> (fridges: [BackupFridge], foods: [BackupFood])
    /// Replaces every fridge and food record in ONE save: either all of it is committed or none of it.
    func replaceInventory(fridges: [BackupFridge], foods: [BackupFood]) throws
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

    func readInventory() throws -> (fridges: [BackupFridge], foods: [BackupFood]) {
        // A fresh context every time, so nothing cached from an earlier read or a failed save leaks in.
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FridgeRecord>(sortBy: [SortDescriptor(\.createdAt)]))
        let createdAt = Dictionary(records.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        // Same mapping (and in-memory layout recovery) the app itself uses; never writes.
        let fridges = try SwiftDataFridgeStore(container: container).loadAll().map {
            BackupFridge($0.fridge, createdAt: createdAt[$0.fridge.id] ?? .now)
        }
        let foods = try context.fetch(FetchDescriptor<FoodItemRecord>()).map { BackupFood($0.item) }
        return (fridges, foods)
    }

    func replaceInventory(fridges: [BackupFridge], foods: [BackupFood]) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let now = Date()

        // Rows are updated in place when their ID is kept (IDs are unique, so delete + insert of the same ID
        // in one save is avoided), deleted when absent from the backup and inserted when new.
        let existingFridges = Dictionary(try context.fetch(FetchDescriptor<FridgeRecord>()).map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        let keptFridges = Set(fridges.map(\.id))
        for (id, record) in existingFridges where !keptFridges.contains(id) { context.delete(record) }
        for backup in fridges {
            let domain = backup.fridge
            let layout = try StoredLayout.encode(domain)
            if let record = existingFridges[backup.id] {
                record.name = domain.name
                record.templateID = domain.templateID
                record.lastDoorStateRaw = domain.lastDoorState.rawValue
                record.layoutData = layout
                record.createdAt = backup.createdAt
                record.updatedAt = now
            } else {
                context.insert(FridgeRecord(id: domain.id, name: domain.name, templateID: domain.templateID,
                                            lastDoorStateRaw: domain.lastDoorState.rawValue, layoutData: layout,
                                            createdAt: backup.createdAt))
            }
        }

        let existingFoods = Dictionary(try context.fetch(FetchDescriptor<FoodItemRecord>()).map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let keptFoods = Set(foods.map(\.id))
        for (id, record) in existingFoods where !keptFoods.contains(id) { context.delete(record) }
        for backup in foods {
            let item = backup.item
            if let record = existingFoods[backup.id] {
                record.apply(item)
                record.createdAt = item.createdAt
                record.updatedAt = item.updatedAt
            } else {
                context.insert(FoodItemRecord(item))
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
