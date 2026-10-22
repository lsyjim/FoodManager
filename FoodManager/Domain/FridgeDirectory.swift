import Foundation

extension Notification.Name {
    /// Posted on the main thread after a fridge was created, renamed or deleted.
    static let fridgesDidChange = Notification.Name("FridgesDidChange")
}

/// Fridge-count and naming rules (free for everyone in Phase 4.1; not tied to Premium).
enum FridgePolicy {
    static let maxRefrigerators = 2
    static let maxNameLength = 20
    static let defaultName = "我的冰箱"
    static let limitMessage = "目前最多可建立 \(maxRefrigerators) 台冰箱。"
}

enum FridgeDirectoryError: Error, Equatable {
    case limitReached
    case invalidName
    case notFound
    case lastFridge
    case hasActiveFood(Int)

    var message: String {
        switch self {
        case .limitReached: return FridgePolicy.limitMessage
        case .invalidName: return "請輸入冰箱名稱（最多 \(FridgePolicy.maxNameLength) 字）"
        case .notFound: return "找不到這台冰箱"
        case .lastFridge: return "至少要保留一台冰箱"
        case let .hasActiveFood(count): return "這台冰箱還有 \(count) 項食材，請先移到另一台冰箱或標記為已食用。"
        }
    }
}

/// Remembers which fridge the user last looked at (a preference, not inventory data).
protocol FridgeSelectionStore: AnyObject {
    var selectedFridgeID: UUID? { get set }
}

final class UserDefaultsFridgeSelectionStore: FridgeSelectionStore {
    static let key = "selectedFridgeID"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var selectedFridgeID: UUID? {
        get { defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.key) }
    }
}

final class InMemoryFridgeSelectionStore: FridgeSelectionStore {
    var selectedFridgeID: UUID?
}

/// What deleting a fridge would do, shown to the user before confirming.
struct FridgeDeletionSummary: Equatable {
    let activeFoodCount: Int
    let historyCount: Int
    /// The fridge that keeps the history (and becomes selected if needed).
    let remainingFridge: Fridge
}

/// All of the user's fridges (at most `FridgePolicy.maxRefrigerators`) and which one is selected.
/// Every change is persisted first; the cached list only updates after a successful save.
final class FridgeDirectory {
    /// Runs after a fridge was deleted from storage (removes magnet photos nothing uses any more).
    var onFridgeDeleted: (() -> Void)?
    let fridgeStore: FridgeStore
    let foodStore: FoodStore
    private let selection: FridgeSelectionStore
    private(set) var results: [FridgeLoadResult]

    init(fridgeStore: FridgeStore, foodStore: FoodStore, selection: FridgeSelectionStore) throws {
        self.fridgeStore = fridgeStore
        self.foodStore = foodStore
        self.selection = selection
        results = try fridgeStore.loadAll()
    }

    var fridges: [Fridge] { results.map(\.fridge) }
    var canAddFridge: Bool { results.count < FridgePolicy.maxRefrigerators }

    /// The stored selection if it still exists, otherwise the oldest fridge.
    var selectedID: UUID {
        if let id = selection.selectedFridgeID, results.contains(where: { $0.fridge.id == id }) { return id }
        return results[0].fridge.id
    }

    var selected: FridgeLoadResult { results.first { $0.fridge.id == selectedID } ?? results[0] }

    func fridge(id: UUID) -> Fridge? { fridges.first { $0.id == id } }
    func contains(_ id: UUID) -> Bool { fridge(id: id) != nil }

    /// Re-reads stored fridges (door states and layouts saved by the home screen).
    func reload() throws {
        results = try fridgeStore.loadAll()
    }

    func select(_ id: UUID) throws {
        try reload()
        guard contains(id) else { throw FridgeDirectoryError.notFound }
        selection.selectedFridgeID = id
    }

    static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= FridgePolicy.maxNameLength else { throw FridgeDirectoryError.invalidName }
        return trimmed
    }

    /// Creates a fridge with the standard template: default layout, or a copy of another fridge's layout
    /// with brand-new compartment IDs. Food is never copied. Does not change the selection.
    @discardableResult
    func create(name: String, copyingLayoutFrom sourceID: UUID? = nil) throws -> Fridge {
        guard canAddFridge else { throw FridgeDirectoryError.limitReached }
        let name = try Self.validatedName(name)
        var fridge = FridgeFactory.makeDefault(name: name)
        if let sourceID {
            guard let source = self.fridge(id: sourceID) else { throw FridgeDirectoryError.notFound }
            fridge.templateID = source.templateID
            for zone in ZoneID.allCases {
                fridge.setCompartments(source.compartments(in: zone).map { Self.copy($0) }, in: zone)
            }
        }
        try fridgeStore.create(fridge)
        try reload()
        post()
        return fridge
    }

    func rename(_ id: UUID, to name: String) throws {
        guard contains(id) else { throw FridgeDirectoryError.notFound }
        try fridgeStore.rename(fridgeID: id, to: try Self.validatedName(name))
        try reload()
        post()
    }

    func deletionSummary(for id: UUID) throws -> FridgeDeletionSummary {
        guard contains(id) else { throw FridgeDirectoryError.notFound }
        guard let remaining = fridges.first(where: { $0.id != id }) else { throw FridgeDirectoryError.lastFridge }
        return FridgeDeletionSummary(activeFoodCount: try foodStore.activeItems(fridgeID: id).count,
                                     historyCount: try foodStore.consumedItems(fridgeID: id).count,
                                     remainingFridge: remaining)
    }

    /// Deletes an empty fridge; its history moves to the remaining fridge. Blocks if food is still inside.
    func delete(_ id: UUID) throws {
        let summary = try deletionSummary(for: id)
        guard summary.activeFoodCount == 0 else { throw FridgeDirectoryError.hasActiveFood(summary.activeFoodCount) }
        do {
            try fridgeStore.deleteFridge(id, moveHistoryTo: summary.remainingFridge.id)
        } catch let FridgeStoreError.fridgeHasActiveFood(count) {
            throw FridgeDirectoryError.hasActiveFood(count)
        }
        if selection.selectedFridgeID == id { selection.selectedFridgeID = summary.remainingFridge.id }
        onFridgeDeleted?()
        try reload()
        post()
    }

    /// Active food of every fridge (notifications, widgets, "所有冰箱" reminders).
    func allActiveItems() throws -> [FoodItem] {
        try fridges.flatMap { try foodStore.activeItems(fridgeID: $0.id) }
    }

    var allCompartments: [Compartment] { fridges.flatMap(\.allCompartments) }
    var namesByID: [UUID: String] { Dictionary(fridges.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    private static func copy(_ compartment: Compartment) -> Compartment {
        Compartment(id: UUID(), parentZoneID: compartment.parentZoneID, name: compartment.name, type: compartment.type,
                    storageType: compartment.storageType, sortOrder: compartment.sortOrder,
                    normalizedFrame: compartment.normalizedFrame)
    }

    private func post() {
        NotificationCenter.default.post(name: .fridgesDidChange, object: self)
    }
}
