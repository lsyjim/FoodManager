import Foundation

// One fridge list for the UI: personal fridges (SwiftData store, mirrored by SwiftData) plus active shared fridges
// (`SharedInventory`, synced by `SharedSyncEngine`). Every call goes to the store that owns the fridge, so a record is
// only ever written by one pipeline. Used only while sharing is active; otherwise the app keeps its plain stores.

final class RoutingFridgeStore: FridgeStore {
    let personal: SwiftDataFridgeStore
    let shared: SharedInventory
    private let personalFood: FoodStore

    init(personal: SwiftDataFridgeStore, shared: SharedInventory, personalFood: FoodStore? = nil) {
        self.personal = personal
        self.shared = shared
        self.personalFood = personalFood ?? SwiftDataFoodStore(container: personal.container)
    }

    /// Where a deleted fridge's history may go, best first (nil: never — someone else's shared fridge).
    /// Personal fridges first, then the user's own unshared, then their shared fridges (whose members see it).
    func historyPriority(_ fridgeID: UUID) -> Int? {
        switch shared.ownership(of: fridgeID) {
        case nil: return 0
        case .personalOwned: return 1
        case .sharedOwned: return 2
        case .sharedParticipant, .pendingInvitation, .unavailableOrRevoked: return nil
        }
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

    /// Deletes an empty fridge; its history moves to `historyDestination` (in whichever store that fridge lives).
    /// A fridge that is currently shared must stop sharing first; a joined fridge is left, not deleted.
    func deleteFridge(_ fridgeID: UUID, moveHistoryTo historyDestination: UUID) throws {
        let sourceIsShared = shared.contains(fridgeID)
        if sourceIsShared {
            switch shared.ownership(of: fridgeID) {
            case .sharedOwned: throw SharingRoutingError.stopSharingFirst
            case .personalOwned: break
            default: throw SharingRoutingError.leaveInstead
            }
        }
        guard historyPriority(historyDestination) != nil else { throw SharingRoutingError.historyNotShared }
        let destinationIsShared = shared.contains(historyDestination)
        guard sourceIsShared || destinationIsShared else {
            return try personal.deleteFridge(fridgeID, moveHistoryTo: historyDestination)
        }

        // Across the two stores: move the history first, then delete the fridge (nothing is lost if that fails).
        let items = sourceIsShared ? try shared.items(fridgeID: fridgeID)
            : try personalFood.activeItems(fridgeID: fridgeID) + personalFood.consumedItems(fridgeID: fridgeID)
        let active = items.filter(\.isActive).count
        guard active == 0 else { throw FridgeStoreError.fridgeHasActiveFood(active) }
        for var item in items {
            item.fridgeID = historyDestination
            if destinationIsShared { try shared.upsert(item) } else { try personalFood.upsert(item) }
            if sourceIsShared && !destinationIsShared { try shared.delete(id: item.id) }
        }
        if sourceIsShared {
            try shared.removeOwnedFridge(fridgeID)
        } else {
            try personal.removeFridgeAfterSharing(fridgeID)
        }
    }

    func mergeFridge(_ sourceID: UUID, into targetID: UUID, compartmentID: UUID) throws {
        guard !shared.contains(sourceID), !shared.contains(targetID) else { throw SharingRoutingError.sharedFridgeLocked }
        try personal.mergeFridge(sourceID, into: targetID, compartmentID: compartmentID)
    }
}

enum SharingRoutingError: Error, Equatable {
    case sharedFridgeLocked
    case stopSharingFirst
    case leaveInstead
    /// History can't be handed to someone else's shared fridge.
    case historyNotShared

    var message: String {
        switch self {
        case .sharedFridgeLocked: return "共享冰箱無法合併。"
        case .stopSharingFirst: return "這台冰箱正在共享中，請先到「成員與申請」停止共享，再刪除冰箱。"
        case .leaveInstead: return "這是別人共享給你的冰箱，請改用「離開共享冰箱」。"
        case .historyNotShared: return "至少要保留一台自己的冰箱，才能刪除這台冰箱。"
        }
    }
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
