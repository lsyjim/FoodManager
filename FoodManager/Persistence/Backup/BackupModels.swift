import Foundation

/// Versioned backup file. Explicit DTOs (never SwiftData objects) so the file format stays stable
/// even if internal storage changes. Not encrypted: it is readable JSON.
///
/// Excluded on purpose: StoreKit transactions, ad identifiers, widget snapshots, caches, Debug switches.
///
/// Format history:
/// - 1 (Phase 4.2): fridges, foods, preferences.
/// - 2 (Phase 4.3): adds `magnets` and `magnetImages` (photo bytes embedded, so the file is self-contained).
///   Both are optional in the file, so version-1 backups still import (as "no magnets").
struct FoodManagerBackup: Codable, Equatable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var exportedAt: Date
    var applicationVersion: String
    var backupID: UUID
    var fridges: [BackupFridge]
    /// Active food and consumed history (history has `consumedAt`).
    var foods: [BackupFood]
    var preferences: BackupPreferences
    /// Fridge magnets (nil in version-1 files).
    var magnets: [FridgeMagnet]?
    /// Photo bytes for photo magnets, one entry per image ID (shared by duplicated magnets).
    var magnetImages: [BackupMagnetImage]?

    var allMagnets: [FridgeMagnet] { magnets ?? [] }
    var allMagnetImages: [BackupMagnetImage] { magnetImages ?? [] }

    /// Everything except the per-file metadata; two backups with equal content restore the same state.
    func hasSameContent(as other: FoodManagerBackup) -> Bool {
        fridges.sorted { $0.id.uuidString < $1.id.uuidString } == other.fridges.sorted { $0.id.uuidString < $1.id.uuidString }
            && foods.sorted { $0.id.uuidString < $1.id.uuidString } == other.foods.sorted { $0.id.uuidString < $1.id.uuidString }
            && preferences == other.preferences
            && allMagnets.sorted { $0.id.uuidString < $1.id.uuidString } == other.allMagnets.sorted { $0.id.uuidString < $1.id.uuidString }
            && allMagnetImages.sorted { $0.id.uuidString < $1.id.uuidString } == other.allMagnetImages.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct BackupFridge: Codable, Equatable {
    var id: UUID
    var name: String
    var templateID: String
    var doorState: DoorState
    /// Keeps the fridges' order (oldest first) after a restore.
    var createdAt: Date
    var cabinetCompartments: [BackupCompartment]
    var doorCompartments: [BackupCompartment]

    init(_ fridge: Fridge, createdAt: Date) {
        id = fridge.id
        name = fridge.name
        templateID = fridge.templateID
        doorState = fridge.lastDoorState
        self.createdAt = createdAt
        cabinetCompartments = fridge.cabinetCompartments.map(BackupCompartment.init)
        doorCompartments = fridge.doorCompartments.map(BackupCompartment.init)
    }

    var fridge: Fridge {
        Fridge(id: id, name: name, templateID: templateID, lastDoorState: doorState,
               cabinetCompartments: cabinetCompartments.map(\.compartment), doorCompartments: doorCompartments.map(\.compartment))
    }

    var allCompartments: [BackupCompartment] { cabinetCompartments + doorCompartments }
}

struct BackupCompartment: Codable, Equatable {
    var id: UUID
    var zone: ZoneID
    var name: String
    var type: CompartmentType
    /// refrigerated / frozen / unspecified — restored exactly, never re-classified.
    var storageType: StorageType
    var sortOrder: Int
    var frame: NormalizedRect

    init(_ compartment: Compartment) {
        id = compartment.id
        zone = compartment.parentZoneID
        name = compartment.name
        type = compartment.type
        storageType = compartment.storageType
        sortOrder = compartment.sortOrder
        frame = compartment.normalizedFrame
    }

    var compartment: Compartment {
        Compartment(id: id, parentZoneID: zone, name: name, type: type, storageType: storageType,
                    sortOrder: sortOrder, normalizedFrame: frame)
    }
}

struct BackupFood: Codable, Equatable {
    var id: UUID
    var name: String
    /// Stable category ID, kept as-is even if this build doesn't know it (shown as 其他).
    var categoryID: String
    /// Decimal as text ("1.5") so the value round-trips exactly.
    var quantity: String
    var unit: String
    var storedAt: Date
    var expirationDate: Date?
    var storageReminderDays: Int?
    var fridgeID: UUID
    var compartmentID: UUID
    var createdAt: Date
    var updatedAt: Date
    var consumedAt: Date?

    static let posix = Locale(identifier: "en_US_POSIX")

    init(_ item: FoodItem) {
        id = item.id
        name = item.name
        categoryID = item.categoryID
        quantity = (item.quantity as NSDecimalNumber).description(withLocale: Self.posix)
        unit = item.unit
        storedAt = item.storedAt
        expirationDate = item.expirationDate
        storageReminderDays = item.storageReminderDays
        fridgeID = item.fridgeID
        compartmentID = item.compartmentID
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        consumedAt = item.consumedAt
    }

    var decimalQuantity: Decimal? {
        guard let value = Decimal(string: quantity, locale: Self.posix), !value.isNaN else { return nil }
        return value
    }

    var item: FoodItem {
        FoodItem(id: id, name: name, categoryID: categoryID, quantity: decimalQuantity ?? 0, unit: unit,
                 storedAt: storedAt, expirationDate: expirationDate, storageReminderDays: storageReminderDays,
                 fridgeID: fridgeID, compartmentID: compartmentID, createdAt: createdAt, updatedAt: updatedAt,
                 consumedAt: consumedAt)
    }
}

struct BackupMagnetImage: Codable, Equatable {
    var id: UUID
    /// The stored display-size image (PNG or JPEG), base64 in JSON.
    var data: Data
}

struct BackupPreferences: Codable, Equatable {
    /// Pinned categories, in the user's order.
    var favoriteCategoryIDs: [String]
    /// Pinned food templates, in the user's order (stable IDs).
    var favoriteFoods: [FavoriteFoodTemplate]
    var notifications: NotificationPreferences
    var selectedFridgeID: UUID?
}

enum BackupCoding {
    /// Dates are stored as exact reference-date seconds so a round trip is lossless.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
