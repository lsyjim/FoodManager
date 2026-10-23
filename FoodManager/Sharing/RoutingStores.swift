import Foundation

// One fridge list for the UI: personal fridges (SwiftData store, mirrored by SwiftData) plus active shared fridges
// (`SharedInventory`, synced by `SharedSyncEngine`). Every call goes to the store that owns the fridge, so a record is
// only ever written by one pipeline. Used only while sharing is active; otherwise the app keeps its plain stores.

final class RoutingFridgeStore: FridgeStore {
    let personal: SwiftDataFridgeStore
    let shared: SharedInventory

    init(personal: SwiftDataFridgeStore, shared: SharedInventory) {
        self.personal = personal
        self.shared = shared
    }

    func load() throws -> FridgeLoadResult { try loadAll()[0] }

    /// Personal fridges first, then shared ones. The default personal fridge is only created when there is no fridge
    /// at all. A personal copy of a shared fridge (its conversion was interrupted) is hidden until it's removed.
    func loadAll() throws -> [FridgeLoadResult] {
        let sharedResults = try shared.loadAll()
        guard !sharedResults.isEmpty else { return try personal.loadAll() }
        let sharedIDs = Set(sharedResults.map(\.fridge.id))
        return try personal.loadExisting().filter { !sharedIDs.contains($0.fridge.id) } + sharedResults
    }

    func saveLayout(_ fridge: Fridge) throws {
        shared.contains(fridge.id) ? try shared.saveLayout(fridge) : try personal.saveLayout(fridge)
    }

    func saveDoorState(_ state: DoorState, fridgeID: UUID) throws {
        shared.contains(fridgeID) ? try shared.saveDoorState(state, fridgeID: fridgeID) : try personal.saveDoorState(state, fridgeID: fridgeID)
    }

    /// New fridges are always personal (sharing is a separate, explicit step).
    func create(_ fridge: Fridge) throws { try personal.create(fridge) }

    func rename(fridgeID: UUID, to name: String) throws {
        shared.contains(fridgeID) ? try shared.rename(fridgeID: fridgeID, to: name) : try personal.rename(fridgeID: fridgeID, to: name)
    }

    /// A shared fridge can't be deleted or merged away here (stopping sharing / leaving comes first), and history of
    /// a deleted personal fridge stays in the personal store (moved to another personal fridge).
    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws {
        guard !shared.contains(fridgeID), !shared.contains(historyDestination) else { throw SharingRoutingError.sharedFridgeLocked }
        try personal.deleteFridge(fridgeID, moveHistoryTo: historyDestination)
    }

    func mergeFridge(_ sourceID: UUID, into targetID: UUID, compartmentID: UUID) throws {
        guard !shared.contains(sourceID), !shared.contains(targetID) else { throw SharingRoutingError.sharedFridgeLocked }
        try personal.mergeFridge(sourceID, into: targetID, compartmentID: compartmentID)
    }
}

enum SharingRoutingError: Error, Equatable {
    case sharedFridgeLocked

    var message: String { "共享中的冰箱無法刪除或合併。" }
}

final class RoutingFoodStore: FoodStore {
    let personal: FoodStore
    let shared: SharedInventory

    init(personal: FoodStore, shared: SharedInventory) {
        self.personal = personal
        self.shared = shared
    }

    func activeItems(fridgeID: UUID) throws -> [FoodItem] {
        guard shared.contains(fridgeID) else { return try personal.activeItems(fridgeID: fridgeID) }
        return try shared.items(fridgeID: fridgeID).filter(\.isActive)
    }

    func consumedItems(fridgeID: UUID) throws -> [FoodItem] {
        guard shared.contains(fridgeID) else { return try personal.consumedItems(fridgeID: fridgeID) }
        return try shared.items(fridgeID: fridgeID).filter { !$0.isActive }
    }

    /// Writes to the store of the item's fridge. Moving between a personal and a shared fridge writes the new copy
    /// first, then removes the old one.
    func upsert(_ item: FoodItem) throws {
        if shared.contains(item.fridgeID) {
            try shared.upsert(item)
            try? personal.delete(id: item.id) // only exists when the food just moved here from a personal fridge
        } else {
            let wasShared = shared.containsFood(item.id)
            try personal.upsert(item)
            if wasShared { try shared.delete(id: item.id) }
        }
    }

    func delete(id: UUID) throws {
        shared.containsFood(id) ? try shared.delete(id: id) : try personal.delete(id: id)
    }

    func unplacedActiveItems(knownFridgeIDs: Set<UUID>) throws -> [FoodItem] {
        try personal.unplacedActiveItems(knownFridgeIDs: knownFridgeIDs)
    }
}

final class RoutingMagnetStore: MagnetStore {
    let personal: MagnetStore
    let shared: SharedInventory

    init(personal: MagnetStore, shared: SharedInventory) {
        self.personal = personal
        self.shared = shared
    }

    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] {
        shared.contains(fridgeID) ? try shared.magnets(fridgeID: fridgeID) : try personal.magnets(fridgeID: fridgeID)
    }

    func allMagnets() throws -> [FridgeMagnet] {
        try personal.allMagnets() + shared.allMagnets()
    }

    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID, newImages: [UUID: Data]) throws {
        guard shared.contains(fridgeID) else { return try personal.replaceMagnets(magnets, fridgeID: fridgeID, newImages: newImages) }
        try shared.replaceMagnets(magnets, fridgeID: fridgeID) { [personal, shared] id in
            newImages[id] ?? (try? shared.imageData(id: id)) ?? (try? personal.imageData(id: id)) ?? nil
        }
    }

    func imageData(id: UUID) throws -> Data? {
        try personal.imageData(id: id) ?? shared.imageData(id: id)
    }

    func storedImageIDs() throws -> Set<UUID> {
        try personal.storedImageIDs().union(shared.storedImageIDs())
    }

    func addImages(_ images: [UUID: Data]) throws {
        try personal.addImages(images)
    }
}
