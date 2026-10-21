import Foundation
import SwiftData

/// SwiftData row for one fridge. The compartment layout is stored as one versioned JSON blob so that
/// saving a layout is a single-row, atomic write and new templates never require a schema migration.
@Model
final class FridgeRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var templateID: String
    var lastDoorStateRaw: String
    var layoutData: Data
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, name: String, templateID: String, lastDoorStateRaw: String, layoutData: Data, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.lastDoorStateRaw = lastDoorStateRaw
        self.layoutData = layoutData
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// On-disk shape of a fridge layout. Bump `currentVersion` and migrate in `decode` if the format changes.
///
/// Version history (all versions decode with the current code; nothing is rewritten until the user saves):
/// - v1 (Phase 1): no `storageType`; door compartments typed `doorRack`.
/// - v2 (Phase 1.1): adds `storageType`; `doorRack` renamed to `doorShelf`. v1 compartments default to
///   `refrigerated` in the cabinet and `unspecified` on the door (see `Compartment.init(from:)`).
struct StoredLayout: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var cabinetCompartments: [Compartment]
    var doorCompartments: [Compartment]

    init(fridge: Fridge) {
        version = Self.currentVersion
        cabinetCompartments = fridge.cabinetCompartments
        doorCompartments = fridge.doorCompartments
    }

    static func encode(_ fridge: Fridge) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(StoredLayout(fridge: fridge))
    }

    static func decode(_ data: Data) throws -> StoredLayout {
        try JSONDecoder().decode(StoredLayout.self, from: data)
    }
}
