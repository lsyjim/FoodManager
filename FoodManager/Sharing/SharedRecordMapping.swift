import CloudKit
import Foundation

// CloudKit layout of a shared refrigerator: two custom zones per fridge, each shared with its own zone-wide CKShare.
//
// | Zone                      | Records                    | Participant permission |
// |---------------------------|----------------------------|------------------------|
// | `Fridge-<id>-Structure`   | SharedFridge, SharedMagnet | read-only              |
// | `Fridge-<id>-Inventory`   | SharedFood, QuantityOp     | read-write             |
//
// The server enforces the split; this file adds the client half of the boundary: structure is only ever read from
// the structure zone, inventory only from the inventory zone, and a record's fridge comes from its zone name (never
// from a field a participant could write). Anything else is ignored.

enum SharedDatabaseScope: String {
    /// The owner's own shared fridges (custom zones in the private database).
    case `private`
    /// Fridges this user joined (the shared database).
    case shared

    var role: SharedFridgeRole { self == .private ? .owner : .participant }
}

enum SharedZoneKind: String {
    case structure = "Structure"
    case inventory = "Inventory"
}

enum SharedZone {
    static func id(fridgeID: UUID, kind: SharedZoneKind, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Fridge-\(fridgeID.uuidString)-\(kind.rawValue)", ownerName: ownerName)
    }

    static func parse(_ zoneID: CKRecordZone.ID) -> (fridgeID: UUID, kind: SharedZoneKind)? {
        let parts = zoneID.zoneName.split(separator: "-", omittingEmptySubsequences: false)
        // "Fridge" + 5 UUID groups + kind
        guard parts.count == 7, parts[0] == "Fridge", let kind = SharedZoneKind(rawValue: String(parts[6])),
              let id = UUID(uuidString: parts[1...5].joined(separator: "-")) else { return nil }
        return (id, kind)
    }
}

enum SharedRecordType {
    static let fridge = "SharedFridge"
    static let magnet = "SharedMagnet"
    static let food = "SharedFood"
    static let quantityOp = "QuantityOp"

    static func zoneKind(of recordType: String) -> SharedZoneKind? {
        switch recordType {
        case fridge, magnet: return .structure
        case food, quantityOp: return .inventory
        default: return nil
        }
    }
}

// MARK: - Field values

struct SharedFridgeFields: Equatable {
    var id: UUID
    var name: String
    var templateID: String
    var layoutData: Data
    var createdAt: Date
    var updatedAt: Date
}

struct SharedFoodFields: Equatable {
    var id: UUID
    var fridgeID: UUID
    var compartmentID: UUID
    var name: String
    var categoryID: String
    var baseQuantity: Decimal
    var foldedOpIDs: [UUID]
    var unit: String
    var storedAt: Date
    var expirationDate: Date?
    var storageReminderDays: Int?
    var createdAt: Date
    var updatedAt: Date
    var consumedAt: Date?
}

struct SharedMagnetFields: Equatable {
    var id: UUID
    var fridgeID: UUID
    var sourceRaw: String
    var builtInAssetID: String?
    var styleRaw: String?
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var zIndex: Int
    var imageData: Data?
    var createdAt: Date
    var updatedAt: Date
}

enum SharedIncoming: Equatable {
    case fridge(SharedFridgeFields)
    case magnet(SharedMagnetFields)
    case food(SharedFoodFields)
    case quantityOp(QuantityOp, fridgeID: UUID)
}

// MARK: - Coding

enum SharedRecordCoder {
    private static let posix = Locale(identifier: "en_US_POSIX")
    static let maxImageBytes = BackupValidator.maxMagnetImageBytes

    /// Validates and decodes a fetched record. nil = ignore it (unknown type, wrong zone, malformed or out of range).
    static func decode(_ record: CKRecord) -> SharedIncoming? {
        guard let zone = SharedZone.parse(record.recordID.zoneID),
              SharedRecordType.zoneKind(of: record.recordType) == zone.kind,
              let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        let fridgeID = zone.fridgeID
        switch record.recordType {
        case SharedRecordType.fridge:
            guard id == fridgeID, let name = record["name"] as? String, let templateID = record["templateID"] as? String,
                  let layoutData = record["layout"] as? Data,
                  let createdAt = record["createdAt"] as? Date, let updatedAt = record["updatedAt"] as? Date,
                  isValidFridge(id: id, name: name, templateID: templateID, layoutData: layoutData) else { return nil }
            return .fridge(SharedFridgeFields(id: id, name: name, templateID: templateID, layoutData: layoutData,
                                              createdAt: createdAt, updatedAt: updatedAt))
        case SharedRecordType.food:
            guard let compartmentText = record["compartmentID"] as? String, let compartmentID = UUID(uuidString: compartmentText),
                  let name = record["name"] as? String, let categoryID = record["categoryID"] as? String,
                  let baseText = record["baseQuantity"] as? String, let base = Decimal(string: baseText, locale: posix),
                  let unit = record["unit"] as? String, let storedAt = record["storedAt"] as? Date,
                  let createdAt = record["createdAt"] as? Date, let updatedAt = record["updatedAt"] as? Date else { return nil }
            let folded = (record["foldedOpIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let fields = SharedFoodFields(id: id, fridgeID: fridgeID, compartmentID: compartmentID, name: name, categoryID: categoryID,
                                          baseQuantity: base, foldedOpIDs: folded, unit: unit, storedAt: storedAt,
                                          expirationDate: record["expirationDate"] as? Date,
                                          storageReminderDays: (record["storageReminderDays"] as? NSNumber)?.intValue,
                                          createdAt: createdAt, updatedAt: updatedAt, consumedAt: record["consumedAt"] as? Date)
            return isValidFood(fields) ? .food(fields) : nil
        case SharedRecordType.quantityOp:
            guard let foodText = record["foodID"] as? String, let foodID = UUID(uuidString: foodText),
                  let deltaText = record["delta"] as? String, let delta = Decimal(string: deltaText, locale: posix),
                  QuantityLedger.isValidDelta(delta), let createdAt = record["createdAt"] as? Date,
                  isValidDate(createdAt) else { return nil }
            return .quantityOp(QuantityOp(id: id, foodID: foodID, delta: delta, createdAt: createdAt), fridgeID: fridgeID)
        case SharedRecordType.magnet:
            guard let sourceRaw = record["source"] as? String, MagnetSource(rawValue: sourceRaw) != nil,
                  let centerX = record["centerX"] as? Double, let centerY = record["centerY"] as? Double,
                  let width = record["width"] as? Double, let height = record["height"] as? Double,
                  let rotation = record["rotation"] as? Double, let zIndex = (record["zIndex"] as? NSNumber)?.intValue,
                  let createdAt = record["createdAt"] as? Date, let updatedAt = record["updatedAt"] as? Date else { return nil }
            var imageData: Data?
            if let url = (record["image"] as? CKAsset)?.fileURL {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxImageBytes else { return nil }
                imageData = try? Data(contentsOf: url)
            }
            let fields = SharedMagnetFields(id: id, fridgeID: fridgeID, sourceRaw: sourceRaw,
                                            builtInAssetID: record["builtInAssetID"] as? String, styleRaw: record["style"] as? String,
                                            centerX: centerX, centerY: centerY, width: width, height: height, rotation: rotation,
                                            zIndex: zIndex, imageData: imageData, createdAt: createdAt, updatedAt: updatedAt)
            return isValidMagnet(fields) ? .magnet(fields) : nil
        default:
            return nil
        }
    }

    // MARK: Encoding

    static func record(type: String, recordName: UUID, zoneID: CKRecordZone.ID, systemFields: Data?) -> CKRecord {
        if let systemFields, let record = restore(systemFields: systemFields),
           record.recordType == type, record.recordID.zoneID == zoneID {
            return record
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: recordName.uuidString, zoneID: zoneID))
    }

    static func encode(_ fields: SharedFridgeFields, ownerName: String, systemFields: Data?) -> CKRecord {
        let record = record(type: SharedRecordType.fridge, recordName: fields.id,
                            zoneID: SharedZone.id(fridgeID: fields.id, kind: .structure, ownerName: ownerName), systemFields: systemFields)
        record["name"] = fields.name
        record["templateID"] = fields.templateID
        record["layout"] = fields.layoutData
        record["createdAt"] = fields.createdAt
        record["updatedAt"] = fields.updatedAt
        return record
    }

    static func encode(_ fields: SharedFoodFields, ownerName: String, systemFields: Data?) -> CKRecord {
        let record = record(type: SharedRecordType.food, recordName: fields.id,
                            zoneID: SharedZone.id(fridgeID: fields.fridgeID, kind: .inventory, ownerName: ownerName), systemFields: systemFields)
        record["compartmentID"] = fields.compartmentID.uuidString
        record["name"] = fields.name
        record["categoryID"] = fields.categoryID
        record["baseQuantity"] = (fields.baseQuantity as NSDecimalNumber).description(withLocale: posix)
        record["foldedOpIDs"] = fields.foldedOpIDs.map(\.uuidString)
        record["unit"] = fields.unit
        record["storedAt"] = fields.storedAt
        record["expirationDate"] = fields.expirationDate
        record["storageReminderDays"] = fields.storageReminderDays.map { NSNumber(value: $0) }
        record["createdAt"] = fields.createdAt
        record["updatedAt"] = fields.updatedAt
        record["consumedAt"] = fields.consumedAt
        return record
    }

    static func encode(_ op: QuantityOp, fridgeID: UUID, ownerName: String, systemFields: Data?) -> CKRecord {
        let record = record(type: SharedRecordType.quantityOp, recordName: op.id,
                            zoneID: SharedZone.id(fridgeID: fridgeID, kind: .inventory, ownerName: ownerName), systemFields: systemFields)
        record["foodID"] = op.foodID.uuidString
        record["delta"] = (op.delta as NSDecimalNumber).description(withLocale: posix)
        record["createdAt"] = op.createdAt
        return record
    }

    /// `imageFileURL`: the photo written to a file for upload (CKAsset needs one).
    static func encode(_ fields: SharedMagnetFields, ownerName: String, imageFileURL: URL?, systemFields: Data?) -> CKRecord {
        let record = record(type: SharedRecordType.magnet, recordName: fields.id,
                            zoneID: SharedZone.id(fridgeID: fields.fridgeID, kind: .structure, ownerName: ownerName), systemFields: systemFields)
        record["source"] = fields.sourceRaw
        record["builtInAssetID"] = fields.builtInAssetID
        record["style"] = fields.styleRaw
        record["centerX"] = fields.centerX
        record["centerY"] = fields.centerY
        record["width"] = fields.width
        record["height"] = fields.height
        record["rotation"] = fields.rotation
        record["zIndex"] = NSNumber(value: fields.zIndex)
        record["image"] = imageFileURL.map(CKAsset.init(fileURL:))
        record["createdAt"] = fields.createdAt
        record["updatedAt"] = fields.updatedAt
        return record
    }

    // MARK: System fields

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restore(systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Validation

    static func isValidFridge(id: UUID, name: String, templateID: String, layoutData: Data) -> Bool {
        guard (try? FridgeDirectory.validatedName(name)) == name, !templateID.isEmpty, templateID.count <= 64,
              let layout = try? StoredLayout.decode(layoutData) else { return false }
        let fridge = Fridge(id: id, name: name, templateID: templateID, lastDoorState: .closed,
                            cabinetCompartments: layout.cabinetCompartments, doorCompartments: layout.doorCompartments)
        return FridgeLayoutEngine.validate(fridge).isEmpty
            && layout.cabinetCompartments.allSatisfy { $0.parentZoneID == .cabinet }
            && layout.doorCompartments.allSatisfy { $0.parentZoneID == .door }
    }

    static func isValidFood(_ food: SharedFoodFields) -> Bool {
        let name = food.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = food.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= FoodValidationError.maxNameLength
            && !unit.isEmpty && unit.count <= FoodValidationError.maxUnitLength
            && !food.categoryID.isEmpty && food.categoryID.count <= 64
            && !food.baseQuantity.isNaN && abs(food.baseQuantity) <= QuantityLedger.maxAbsoluteDelta
            && food.foldedOpIDs.count <= QuantityLedger.maxFoldedIDs
            && (food.storageReminderDays.map(FoodValidationError.reminderDayRange.contains) ?? true)
            && [food.storedAt, food.createdAt, food.updatedAt].allSatisfy(isValidDate)
            && (food.expirationDate.map(isValidDate) ?? true)
            && (food.consumedAt.map(isValidDate) ?? true)
    }

    static func isValidMagnet(_ magnet: SharedMagnetFields) -> Bool {
        let values = [magnet.centerX, magnet.centerY, magnet.width, magnet.height, magnet.rotation]
        let tolerance = 1e-6
        guard values.allSatisfy(\.isFinite), (0...1_000).contains(magnet.zIndex),
              isValidDate(magnet.createdAt), isValidDate(magnet.updatedAt),
              (magnet.builtInAssetID?.count ?? 0) <= 64, (magnet.styleRaw?.count ?? 0) <= 64 else { return false }
        let source = MagnetSource(rawValue: magnet.sourceRaw)
        return MagnetGeometry.centerRange.contains(magnet.centerX) && MagnetGeometry.centerRange.contains(magnet.centerY)
            && magnet.width >= MagnetGeometry.minWidth - tolerance && magnet.width <= MagnetGeometry.maxWidth + tolerance
            && magnet.height > 0 && magnet.height <= 3 && abs(magnet.rotation) <= .pi + tolerance
            && (source == .builtIn ? magnet.builtInAssetID?.isEmpty == false : magnet.imageData != nil)
    }

    private static func isValidDate(_ date: Date) -> Bool {
        date >= BackupValidator.earliestDate && date <= BackupValidator.latestDate
    }
}
