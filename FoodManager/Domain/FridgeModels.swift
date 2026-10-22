import Foundation

/// Whether the fridge door is currently shown open or closed. Persisted so the app restores it on relaunch.
enum DoorState: String, Codable, CaseIterable {
    case closed
    case open
}

/// The independently editable regions of a fridge. Each zone has its own normalized coordinate space.
/// A zone is a physical container only; it says nothing about temperature (see `StorageType`).
enum ZoneID: String, Codable, CaseIterable {
    case cabinet
    case door

    /// Compartment types a zone accepts.
    var allowedTypes: [CompartmentType] {
        switch self {
        case .cabinet: return [.shelf, .drawer]
        case .door: return [.doorShelf]
        }
    }

    /// Storage classifications a zone accepts. Door compartments are unclassified for the standard
    /// template; a future template can widen this without changing the stored data format.
    var allowedStorageTypes: [StorageType] {
        switch self {
        case .cabinet: return [.refrigerated, .frozen]
        case .door: return [.unspecified]
        }
    }

    /// Classification used for new compartments and for legacy data saved before `storageType` existed.
    var defaultStorageType: StorageType {
        switch self {
        case .cabinet: return .refrigerated
        case .door: return .unspecified
        }
    }

    var displayName: String {
        switch self {
        case .cabinet: return "櫃內"
        case .door: return "門內"
        }
    }
}

/// Physical structure of a compartment.
enum CompartmentType: String, Codable, CaseIterable {
    case shelf
    case drawer
    case doorShelf

    /// Raw value written by Phase 1 builds before `doorShelf` was renamed.
    private static let legacyDoorRackRawValue = "doorRack"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = CompartmentType(rawValue: raw) {
            self = value
        } else if raw == Self.legacyDoorRackRawValue {
            self = .doorShelf
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown compartment type \(raw)"))
        }
    }

    var displayName: String {
        switch self {
        case .shelf: return "層架"
        case .drawer: return "抽屜"
        case .doorShelf: return "門架"
        }
    }

    /// Height used when a new compartment of this type is added (fraction of the zone).
    var defaultHeight: Double {
        switch self {
        case .shelf: return 0.22
        case .drawer: return 0.22
        case .doorShelf: return 0.28
        }
    }
}

/// A rectangle in unit space (0...1 on both axes), relative to some parent rectangle.
struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minY: Double { y }
    var maxY: Double { y + height }
    var maxX: Double { x + width }
}

struct Compartment: Equatable, Identifiable {
    let id: UUID
    var parentZoneID: ZoneID
    var name: String
    var type: CompartmentType
    var storageType: StorageType
    var sortOrder: Int
    /// Frame relative to the parent zone's editable rect (0...1).
    var normalizedFrame: NormalizedRect
}

extension Compartment: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, parentZoneID, name, type, storageType, sortOrder, normalizedFrame
    }

    /// Accepts Phase 1 data (no `storageType`): the classification defaults from the parent zone.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        parentZoneID = try c.decode(ZoneID.self, forKey: .parentZoneID)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(CompartmentType.self, forKey: .type)
        storageType = try c.decodeIfPresent(StorageType.self, forKey: .storageType) ?? parentZoneID.defaultStorageType
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        normalizedFrame = try c.decode(NormalizedRect.self, forKey: .normalizedFrame)
    }
}

/// Domain value for one refrigerator. Value semantics make every copy a deep, isolated copy.
struct Fridge: Equatable, Identifiable {
    let id: UUID
    var name: String
    var templateID: String
    var lastDoorState: DoorState
    var cabinetCompartments: [Compartment]
    var doorCompartments: [Compartment]

    func compartments(in zone: ZoneID) -> [Compartment] {
        switch zone {
        case .cabinet: return cabinetCompartments
        case .door: return doorCompartments
        }
    }

    mutating func setCompartments(_ compartments: [Compartment], in zone: ZoneID) {
        switch zone {
        case .cabinet: cabinetCompartments = compartments
        case .door: doorCompartments = compartments
        }
    }

    var allCompartments: [Compartment] { cabinetCompartments + doorCompartments }
}
