import Foundation

enum LayoutEditError: Error, Equatable {
    case compartmentNotFound
    case typeNotAllowed(CompartmentType, ZoneID)
    case storageTypeNotAllowed(StorageType, ZoneID)
    case notEnoughSpace
    case belowMinimumHeight
    case invalidName
    /// Phase 2: compartments holding food must be emptied/relocated first; food is never deleted implicitly.
    case compartmentOccupied(itemCount: Int)
    case invalidLayout([LayoutValidationError])

    var message: String {
        switch self {
        case .compartmentNotFound: return "找不到這個隔層"
        case let .typeNotAllowed(type, zone): return "\(zone.displayName)不能加入\(type.displayName)"
        case let .storageTypeNotAllowed(storage, zone): return "\(zone.displayName)不能設為\(storage.displayName)"
        case .notEnoughSpace: return "空間不足"
        case .belowMinimumHeight: return "已達最小高度"
        case .invalidName: return "名稱不可空白，且最多 \(FridgeLayoutEngine.maxNameLength) 字"
        case let .compartmentOccupied(count): return "此隔層還有 \(count) 項食材，請先移到其他隔層"
        case let .invalidLayout(errors): return errors.first?.message ?? "版面無效"
        }
    }
}

/// The five things a user can add in Phase 1.1. Maps a menu choice to structure, classification and zone.
enum AddCompartmentOption: CaseIterable {
    case refrigeratedShelf
    case frozenShelf
    case refrigeratedDrawer
    case frozenDrawer
    case doorShelf

    var type: CompartmentType {
        switch self {
        case .refrigeratedShelf, .frozenShelf: return .shelf
        case .refrigeratedDrawer, .frozenDrawer: return .drawer
        case .doorShelf: return .doorShelf
        }
    }

    var storageType: StorageType {
        switch self {
        case .refrigeratedShelf, .refrigeratedDrawer: return .refrigerated
        case .frozenShelf, .frozenDrawer: return .frozen
        case .doorShelf: return .unspecified
        }
    }

    var zone: ZoneID { self == .doorShelf ? .door : .cabinet }

    var title: String {
        storageType == .unspecified ? type.displayName : storageType.displayName + type.displayName
    }
}

enum MoveDirection {
    case up
    case down
}

/// An edit transaction over an isolated working copy of a fridge.
/// Every mutation is validated before it is applied, so `working` is always a valid layout.
/// The original is never touched; Cancel simply discards the editor.
final class FridgeLayoutEditor {
    static let heightStep: Double = 0.02

    let original: Fridge
    private(set) var working: Fridge
    private let occupancy: CompartmentOccupancyProviding

    var hasChanges: Bool { working != original }

    init(fridge: Fridge, occupancy: CompartmentOccupancyProviding = EmptyOccupancyProvider()) {
        original = fridge
        working = fridge
        self.occupancy = occupancy
    }

    func compartment(id: UUID) -> Compartment? {
        working.allCompartments.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func addCompartment(_ option: AddCompartmentOption) throws -> Compartment {
        try addCompartment(type: option.type, storage: option.storageType, to: option.zone)
    }

    /// Appends a compartment at the bottom of the zone. `storage` defaults to the zone's default classification.
    @discardableResult
    func addCompartment(type: CompartmentType, storage: StorageType? = nil, to zone: ZoneID) throws -> Compartment {
        guard zone.allowedTypes.contains(type) else { throw LayoutEditError.typeNotAllowed(type, zone) }
        let storage = storage ?? zone.defaultStorageType
        guard zone.allowedStorageTypes.contains(storage) else { throw LayoutEditError.storageTypeNotAllowed(storage, zone) }
        let existing = working.compartments(in: zone)
        let available = FridgeLayoutEngine.availableHeightForNewCompartment(in: existing)
        guard available >= FridgeLayoutEngine.minHeight - FridgeLayoutEngine.tolerance else {
            throw LayoutEditError.notEnoughSpace
        }
        let sameKindCount = existing.filter { $0.type == type && $0.storageType == storage }.count
        let prefix = storage == .unspecified ? type.displayName : storage.displayName + type.displayName
        let new = Compartment(id: UUID(), parentZoneID: zone, name: "\(prefix) \(sameKindCount + 1)",
                              type: type, storageType: storage,
                              sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
                              normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1,
                                                              height: min(type.defaultHeight, available)))
        try apply(in: zone) { $0 + [new] }
        return new
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FridgeLayoutEngine.isValidName(trimmed) else { throw LayoutEditError.invalidName }
        try update(id) { $0.name = trimmed }
    }

    /// Reclassifies a compartment in place: same ID, same position, same size.
    func setStorageType(_ id: UUID, to storage: StorageType) throws {
        let zone = try zoneOf(id)
        guard zone.allowedStorageTypes.contains(storage) else { throw LayoutEditError.storageTypeNotAllowed(storage, zone) }
        try update(id) { $0.storageType = storage }
    }

    /// Swaps the compartment with its neighbour. Moving past either end is a no-op.
    func move(_ id: UUID, _ direction: MoveDirection) throws {
        let zone = try zoneOf(id)
        try apply(in: zone) { compartments in
            var ordered = compartments.sorted { $0.sortOrder < $1.sortOrder }
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { throw LayoutEditError.compartmentNotFound }
            let target = direction == .up ? index - 1 : index + 1
            guard ordered.indices.contains(target) else { return compartments }
            ordered.swapAt(index, target)
            for i in ordered.indices { ordered[i].sortOrder = i }
            return ordered
        }
    }

    func resize(_ id: UUID, by delta: Double) throws {
        guard let current = compartment(id: id) else { throw LayoutEditError.compartmentNotFound }
        try setHeight(id, to: current.normalizedFrame.height + delta)
    }

    /// Heights below `minHeight` are rejected when shrinking; a legacy compartment that is already
    /// smaller may still grow back toward the minimum.
    func setHeight(_ id: UUID, to height: Double) throws {
        guard let current = compartment(id: id) else { throw LayoutEditError.compartmentNotFound }
        let isShrinking = height < current.normalizedFrame.height
        guard height >= FridgeLayoutEngine.minHeight - FridgeLayoutEngine.tolerance || !isShrinking else {
            throw LayoutEditError.belowMinimumHeight
        }
        try update(id) { $0.normalizedFrame.height = (height * 1000).rounded() / 1000 }
    }

    func delete(_ id: UUID) throws {
        let zone = try zoneOf(id)
        let count = occupancy.itemCount(in: id)
        guard count == 0 else { throw LayoutEditError.compartmentOccupied(itemCount: count) }
        try apply(in: zone) { $0.filter { $0.id != id } }
    }

    /// Final whole-fridge validation; returns the fridge to persist.
    func commit() throws -> Fridge {
        let errors = FridgeLayoutEngine.validate(working)
        guard errors.isEmpty else { throw LayoutEditError.invalidLayout(errors) }
        return working
    }

    // MARK: - Helpers

    private func zoneOf(_ id: UUID) throws -> ZoneID {
        guard let zone = compartment(id: id)?.parentZoneID else { throw LayoutEditError.compartmentNotFound }
        return zone
    }

    private func update(_ id: UUID, _ change: @escaping (inout Compartment) -> Void) throws {
        let zone = try zoneOf(id)
        try apply(in: zone) { compartments in
            compartments.map { c in
                guard c.id == id else { return c }
                var copy = c
                change(&copy)
                return copy
            }
        }
    }

    /// Runs a transform on a copy of one zone, re-packs and validates it, and only then commits it to `working`.
    private func apply(in zone: ZoneID, _ transform: ([Compartment]) throws -> [Compartment]) throws {
        let candidate = FridgeLayoutEngine.pack(try transform(working.compartments(in: zone)))
        let errors = FridgeLayoutEngine.validate(candidate, in: zone)
        guard errors.isEmpty else {
            if errors.contains(where: { if case .outOfBounds = $0 { return true } else { return false } }) {
                throw LayoutEditError.notEnoughSpace
            }
            if errors.contains(where: { if case .tooSmall = $0 { return true } else { return false } }) {
                throw LayoutEditError.belowMinimumHeight
            }
            throw LayoutEditError.invalidLayout(errors)
        }
        working.setCompartments(candidate, in: zone)
    }
}
