import Foundation
import os

extension Notification.Name {
    /// Posted (on the main thread) after any successful food mutation so every screen can refresh.
    static let foodInventoryDidChange = Notification.Name("FoodInventoryDidChange")
    /// Posted after the user saves food with an expiration date or storage reminder (contextual
    /// moment to offer notification permission).
    static let foodReminderConfigured = Notification.Name("FoodReminderConfigured")
}

/// Editable fields of a food record, used by the add/edit screen before anything is persisted.
struct FoodDraft: Equatable {
    var name = ""
    var categoryID = FoodCategoryCatalog.otherID
    var quantity: Decimal = 1
    var unit = "個"
    var storedAt: Date
    var expirationDate: Date?
    var storageReminderDays: Int?
    /// nil until the user picks a destination (global add) — validation then requires one.
    var compartmentID: UUID?

    init(compartmentID: UUID? = nil, now: Date = Date()) {
        self.compartmentID = compartmentID
        storedAt = now
    }

    init(item: FoodItem) {
        name = item.name
        categoryID = item.categoryID
        quantity = item.quantity
        unit = item.unit
        storedAt = item.storedAt
        expirationDate = item.expirationDate
        storageReminderDays = item.storageReminderDays
        compartmentID = item.compartmentID
    }
}

enum FoodValidationError: Error, Equatable {
    case emptyName
    case nameTooLong
    case negativeQuantity
    /// Not an input mistake: the UI answers it by offering "mark as consumed".
    case zeroQuantity
    case emptyUnit
    case unitTooLong
    case compartmentRequired
    case compartmentNotFound
    case unknownCategory
    case invalidReminderDays

    static let maxNameLength = 30
    static let maxUnitLength = 8
    static let reminderDayRange = 1...3650

    var message: String {
        switch self {
        case .emptyName: return "請輸入食材名稱"
        case .nameTooLong: return "名稱最多 \(Self.maxNameLength) 字"
        case .negativeQuantity: return "數量不能是負數"
        case .zeroQuantity: return "數量為 0"
        case .emptyUnit: return "請輸入單位"
        case .unitTooLong: return "單位最多 \(Self.maxUnitLength) 字"
        case .compartmentRequired: return "請選擇存放位置"
        case .compartmentNotFound: return "存放位置已不存在，請重新選擇"
        case .unknownCategory: return "請選擇分類"
        case .invalidReminderDays: return "保存提醒天數需介於 1 到 3650 天"
        }
    }
}

/// Result of the most recent read. `failed` is never shown as an empty fridge.
enum FoodLoadState: Equatable {
    case loading
    case loaded
    case failed

    var isFailed: Bool { self == .failed }
}

/// Business rules for the food inventory: validation, quantity rules, moving, consuming and search.
/// Keeps an in-memory snapshot of active items for the fridge; every mutation persists first, then refreshes.
final class FoodInventoryService {
    let fridgeID: UUID
    var now: () -> Date
    private let store: FoodStore
    private let compartments: () -> [Compartment]
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Inventory")

    /// Active (not consumed) items of this fridge, including any whose compartment no longer exists.
    /// After a failed read this keeps the last successfully loaded items instead of becoming empty.
    private(set) var items: [FoodItem] = []
    private(set) var loadState: FoodLoadState = .loading
    /// True only when a successful read returned no active food (distinct from a failed read).
    var isEmpty: Bool { loadState == .loaded && items.isEmpty }

    init(store: FoodStore, fridgeID: UUID, compartments: @escaping () -> [Compartment], now: @escaping () -> Date = Date.init) {
        self.store = store
        self.fridgeID = fridgeID
        self.compartments = compartments
        self.now = now
        reload()
    }

    /// Re-reads active food. Returns false (and keeps the previous items) when the read fails.
    @discardableResult
    func reload() -> Bool {
        do {
            items = try store.activeItems(fridgeID: fridgeID)
            loadState = .loaded
            return true
        } catch {
            logger.error("Failed to load food: \(String(describing: error), privacy: .private)")
            loadState = .failed
            return false
        }
    }

    /// User-initiated retry after a failed read; notifies observers so every screen refreshes.
    func retryLoading() {
        reload()
        NotificationCenter.default.post(name: .foodInventoryDidChange, object: self)
    }

    // MARK: - Queries

    func item(id: UUID) -> FoodItem? { items.first { $0.id == id } }

    func items(in compartmentID: UUID) -> [FoodItem] { items.filter { $0.compartmentID == compartmentID } }

    func compartment(for item: FoodItem) -> Compartment? {
        compartments().first { $0.id == item.compartmentID }
    }

    /// Items whose compartment was removed outside the normal rules. They stay visible (search, All totals).
    var itemsWithMissingCompartment: [FoodItem] {
        let ids = Set(compartments().map(\.id))
        return items.filter { !ids.contains($0.compartmentID) }
    }

    func contentSummary(for compartmentID: UUID) -> CompartmentContentSummary {
        CompartmentContentSummary(items: items(in: compartmentID))
    }

    /// Case- and width-insensitive name search. An empty query lists everything.
    func search(_ query: String) -> [FoodItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty ? items : items.filter { $0.name.localizedStandardContains(trimmed) }
        return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Validation

    /// Returns the validated destination compartment ID.
    @discardableResult
    func validate(_ draft: FoodDraft) throws -> UUID {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw FoodValidationError.emptyName }
        if name.count > FoodValidationError.maxNameLength { throw FoodValidationError.nameTooLong }
        if !FoodCategoryCatalog.contains(draft.categoryID) { throw FoodValidationError.unknownCategory }
        if draft.quantity < 0 { throw FoodValidationError.negativeQuantity }
        if draft.quantity == 0 { throw FoodValidationError.zeroQuantity }
        if unit.isEmpty { throw FoodValidationError.emptyUnit }
        if unit.count > FoodValidationError.maxUnitLength { throw FoodValidationError.unitTooLong }
        if let days = draft.storageReminderDays, !FoodValidationError.reminderDayRange.contains(days) {
            throw FoodValidationError.invalidReminderDays
        }
        guard let compartmentID = draft.compartmentID else { throw FoodValidationError.compartmentRequired }
        guard compartments().contains(where: { $0.id == compartmentID }) else { throw FoodValidationError.compartmentNotFound }
        return compartmentID
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ draft: FoodDraft) throws -> FoodItem {
        let compartmentID = try validate(draft)
        let timestamp = now()
        var item = FoodItem(id: UUID(), name: "", categoryID: "", quantity: 0, unit: "", storedAt: draft.storedAt,
                            fridgeID: fridgeID, compartmentID: compartmentID, createdAt: timestamp, updatedAt: timestamp)
        apply(draft, to: &item)
        try persist(item)
        return item
    }

    /// Replaces the editable fields of an existing record. The ID and creation date never change.
    @discardableResult
    func update(_ id: UUID, with draft: FoodDraft) throws -> FoodItem {
        guard var item = item(id: id) else { throw FoodStoreError.notFound }
        try validate(draft)
        apply(draft, to: &item)
        item.updatedAt = now()
        try persist(item)
        return item
    }

    /// Quick +/- adjustment. Never goes below zero: reaching zero throws `.zeroQuantity` without saving,
    /// so the UI can offer "mark as consumed" instead of silently deleting.
    @discardableResult
    func adjustQuantity(_ id: UUID, by delta: Decimal) throws -> FoodItem {
        guard var item = item(id: id) else { throw FoodStoreError.notFound }
        let newValue = item.quantity + delta
        if newValue <= 0 { throw FoodValidationError.zeroQuantity }
        item.quantity = newValue
        item.updatedAt = now()
        try persist(item)
        return item
    }

    /// Moves the same record (same ID, same dates) to another compartment.
    func move(_ id: UUID, to compartmentID: UUID) throws {
        guard var item = item(id: id) else { throw FoodStoreError.notFound }
        guard compartments().contains(where: { $0.id == compartmentID }) else { throw FoodValidationError.compartmentNotFound }
        item.compartmentID = compartmentID
        item.updatedAt = now()
        try persist(item)
    }

    /// Removes the item from the active inventory (kept in storage with `consumedAt`).
    func markConsumed(_ id: UUID) throws {
        guard var item = item(id: id) else { throw FoodStoreError.notFound }
        let timestamp = now()
        item.consumedAt = timestamp
        item.updatedAt = timestamp
        try persist(item)
    }

    /// Permanently deletes a record entered by mistake. Only reachable through an explicit, confirmed action.
    func delete(_ id: UUID) throws {
        try store.delete(id: id)
        didChange(removed: id)
    }

    // MARK: - Private

    private func apply(_ draft: FoodDraft, to item: inout FoodItem) {
        item.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.categoryID = draft.categoryID
        item.quantity = draft.quantity
        item.unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        item.storedAt = draft.storedAt
        item.expirationDate = draft.expirationDate
        item.storageReminderDays = draft.storageReminderDays
        if let compartmentID = draft.compartmentID { item.compartmentID = compartmentID }
    }

    /// Writes first; the in-memory snapshot and observers only update after the write succeeded,
    /// so a failed save never looks like a successful one.
    private func persist(_ item: FoodItem) throws {
        try store.upsert(item)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if item.isActive { items[index] = item } else { items.remove(at: index) }
        } else if item.isActive {
            items.append(item)
        }
        didChange(removed: nil)
    }

    private func didChange(removed: UUID?) {
        if let removed { items.removeAll { $0.id == removed } }
        // Refresh from storage too; if that read fails the locally updated snapshot is kept.
        reload()
        NotificationCenter.default.post(name: .foodInventoryDidChange, object: self)
    }
}

extension FoodInventoryService: CompartmentOccupancyProviding {
    func itemCount(in compartmentID: UUID) -> Int { items(in: compartmentID).count }
}
