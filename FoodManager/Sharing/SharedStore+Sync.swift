import CloudKit
import Foundation
import SwiftData

/// What applying one fetched batch did (for logging and tests; contains no record contents).
struct SharedApplyReport: Equatable {
    var applied = 0
    var ignored = 0
    var deleted = 0
}

extension SharedStore {
    // MARK: Incoming

    /// Applies fetched changes in one save. Invalid or misplaced records are ignored, never partially applied.
    @discardableResult
    func apply(modifications: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)],
               scope: SharedDatabaseScope) throws -> SharedApplyReport {
        let context = makeContext()
        var report = SharedApplyReport()
        for record in modifications {
            guard let incoming = SharedRecordCoder.decode(record) else {
                report.ignored += 1
                continue
            }
            let systemFields = SharedRecordCoder.systemFields(of: record)
            switch incoming {
            case let .fridge(fields):
                let row = try fetchFridge(fields.id, in: context)
                    ?? insert(SharedFridgeRecord(id: fields.id, role: scope.role, zoneOwnerName: record.recordID.zoneID.ownerName), in: context)
                guard row.role == scope.role else { report.ignored += 1; continue }
                row.name = fields.name
                row.templateID = fields.templateID
                row.layoutData = fields.layoutData
                row.createdAt = fields.createdAt
                row.updatedAt = fields.updatedAt
                // Readable structure means the owner approved this account.
                row.statusRaw = SharedFridgeStatus.active.rawValue
                if scope == .shared { row.isShared = true }
                row.systemFields = systemFields
            case let .food(fields):
                let id = fields.id
                let row = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first
                    ?? insert(SharedFoodRecord(id: fields.id, fridgeID: fields.fridgeID), in: context)
                guard row.fridgeID == fields.fridgeID else { report.ignored += 1; continue }
                row.compartmentID = fields.compartmentID
                row.name = fields.name
                row.categoryID = fields.categoryID
                row.baseQuantity = fields.baseQuantity
                row.foldedOpIDs = fields.foldedOpIDs
                row.unit = fields.unit
                row.storedAt = fields.storedAt
                row.expirationDate = fields.expirationDate
                row.storageReminderDays = fields.storageReminderDays
                row.createdAt = fields.createdAt
                row.updatedAt = fields.updatedAt
                row.consumedAt = fields.consumedAt
                row.systemFields = systemFields
            case let .quantityOp(op, fridgeID):
                // Ops are immutable: an existing one (a re-delivery) only refreshes its system fields.
                let id = op.id
                if let row = try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.id == id })).first {
                    row.systemFields = systemFields
                } else {
                    let row = SharedQuantityOpRecord(op, fridgeID: fridgeID)
                    row.systemFields = systemFields
                    context.insert(row)
                }
            case let .magnet(fields):
                let id = fields.id
                let row = try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.id == id })).first
                    ?? insert(SharedMagnetRecord(id: fields.id, fridgeID: fields.fridgeID), in: context)
                guard row.fridgeID == fields.fridgeID else { report.ignored += 1; continue }
                row.sourceRaw = fields.sourceRaw
                row.builtInAssetID = fields.builtInAssetID
                row.styleRaw = fields.styleRaw
                row.centerX = fields.centerX
                row.centerY = fields.centerY
                row.width = fields.width
                row.height = fields.height
                row.rotation = fields.rotation
                row.zIndex = fields.zIndex
                row.imageData = fields.imageData
                row.createdAt = fields.createdAt
                row.updatedAt = fields.updatedAt
                row.systemFields = systemFields
            }
            report.applied += 1
        }

        var purgedFridges: [UUID] = []
        for (recordID, recordType) in deletions {
            guard let zone = SharedZone.parse(recordID.zoneID), SharedRecordType.zoneKind(of: recordType) == zone.kind,
                  let id = UUID(uuidString: recordID.recordName) else {
                report.ignored += 1
                continue
            }
            switch recordType {
            case SharedRecordType.fridge where id == zone.fridgeID:
                purgedFridges.append(id)
            case SharedRecordType.food:
                try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
                try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.foodID == id })).forEach(context.delete)
            case SharedRecordType.quantityOp:
                try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
            case SharedRecordType.magnet:
                try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
            default:
                report.ignored += 1
                continue
            }
            report.deleted += 1
        }
        try context.save()
        for fridgeID in purgedFridges {
            try purgeFridge(fridgeID, keepPlaceholder: scope == .shared)
        }
        return report
    }

    /// A shared zone disappeared (owner stopped sharing, removed this member, or deleted it).
    func zoneWasDeleted(_ zoneID: CKRecordZone.ID, scope: SharedDatabaseScope) throws {
        guard let zone = SharedZone.parse(zoneID) else { return }
        try purgeFridge(zone.fridgeID, keepPlaceholder: scope == .shared)
    }

    // MARK: Outgoing

    /// The record to upload for a pending change, or nil when there's nothing (left) to send. A participant never
    /// produces structure records: the server would reject them anyway, and the UI must not pretend otherwise.
    func outgoingRecord(for recordID: CKRecord.ID, scope: SharedDatabaseScope,
                        imageFileURL: (UUID, Data) -> URL? = SharedStore.writeUploadFile) throws -> CKRecord? {
        guard let zone = SharedZone.parse(recordID.zoneID), let id = UUID(uuidString: recordID.recordName) else { return nil }
        let context = makeContext()
        guard let fridge = try fetchFridge(zone.fridgeID, in: context), fridge.role == scope.role,
              fridge.status != .unavailable else { return nil }
        let ownerName = recordID.zoneID.ownerName
        switch zone.kind {
        case .structure:
            guard scope == .private else { return nil }
            if id == fridge.id {
                return SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                                   layoutData: fridge.layoutData, createdAt: fridge.createdAt,
                                                                   updatedAt: fridge.updatedAt),
                                                ownerName: ownerName, systemFields: fridge.systemFields)
            }
            guard let magnet = try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.id == id })).first,
                  magnet.fridgeID == fridge.id else { return nil }
            let fields = SharedMagnetFields(id: magnet.id, fridgeID: magnet.fridgeID, sourceRaw: magnet.sourceRaw,
                                            builtInAssetID: magnet.builtInAssetID, styleRaw: magnet.styleRaw,
                                            centerX: magnet.centerX, centerY: magnet.centerY, width: magnet.width,
                                            height: magnet.height, rotation: magnet.rotation, zIndex: magnet.zIndex,
                                            imageData: magnet.imageData, createdAt: magnet.createdAt, updatedAt: magnet.updatedAt)
            return SharedRecordCoder.encode(fields, ownerName: ownerName, imageFileURL: magnet.imageData.flatMap { imageFileURL(magnet.id, $0) },
                                            systemFields: magnet.systemFields)
        case .inventory:
            if let food = try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first,
               food.fridgeID == fridge.id {
                let fields = SharedFoodFields(id: food.id, fridgeID: food.fridgeID, compartmentID: food.compartmentID, name: food.name,
                                              categoryID: food.categoryID, baseQuantity: food.baseQuantity, foldedOpIDs: food.foldedOpIDs,
                                              unit: food.unit, storedAt: food.storedAt, expirationDate: food.expirationDate,
                                              storageReminderDays: food.storageReminderDays, createdAt: food.createdAt,
                                              updatedAt: food.updatedAt, consumedAt: food.consumedAt)
                return SharedRecordCoder.encode(fields, ownerName: ownerName, systemFields: food.systemFields)
            }
            if let op = try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.id == id })).first,
               op.fridgeID == fridge.id {
                return SharedRecordCoder.encode(op.op, fridgeID: fridge.id, ownerName: ownerName, systemFields: op.systemFields)
            }
            return nil
        }
    }

    /// Stores the server's system fields after a successful upload.
    func didSave(_ record: CKRecord) throws {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return }
        let context = makeContext()
        let fields = SharedRecordCoder.systemFields(of: record)
        switch record.recordType {
        case SharedRecordType.fridge:
            try fetchFridge(id, in: context)?.systemFields = fields
        case SharedRecordType.food:
            try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = fields
        case SharedRecordType.quantityOp:
            try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = fields
        case SharedRecordType.magnet:
            try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = fields
        default:
            return
        }
        try context.save()
    }

    /// Forgets a record's change tag (the server no longer has it), so the next upload creates it again.
    func clearSystemFields(recordID: CKRecord.ID) throws {
        guard let id = UUID(uuidString: recordID.recordName) else { return }
        let context = makeContext()
        try fetchFridge(id, in: context)?.systemFields = nil
        try context.fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = nil
        try context.fetch(FetchDescriptor<SharedQuantityOpRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = nil
        try context.fetch(FetchDescriptor<SharedMagnetRecord>(predicate: #Predicate { $0.id == id })).first?.systemFields = nil
        try context.save()
    }

    /// Local updatedAt of a food (for last-writer-wins on its non-quantity fields).
    func foodUpdatedAt(_ id: UUID) throws -> Date? {
        try makeContext().fetch(FetchDescriptor<SharedFoodRecord>(predicate: #Predicate { $0.id == id })).first?.updatedAt
    }

    /// CKAsset upload file for a photo, in Caches (CloudKit reads it during the upload).
    static func writeUploadFile(id: UUID, data: Data) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("SharedUploads", isDirectory: true)
        let url = directory.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Helpers

    private func fetchFridge(_ id: UUID, in context: ModelContext) throws -> SharedFridgeRecord? {
        try context.fetch(FetchDescriptor<SharedFridgeRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func insert<T: PersistentModel>(_ model: T, in context: ModelContext) -> T {
        context.insert(model)
        return model
    }
}
