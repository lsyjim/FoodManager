import Foundation
import SwiftData

/// Rows that may exist more than once with the same app ID.
///
/// CloudKit can't enforce unique constraints, so the same logical record can arrive twice (e.g. the same backup
/// restored on two devices before they synced). Such rows are never deleted as "duplicates": two devices doing
/// that at the same time could each delete a different copy and lose the record. Instead reads collapse them
/// (the newest wins, with a deterministic tie-break every device agrees on) and writes update all of them.
protocol SyncedRecord: AnyObject {
    var id: UUID { get }
    var updatedAt: Date { get }
    /// Tie-break when `updatedAt` is equal: any stable value derived from the content.
    var syncTieBreaker: String { get }
}

enum SyncedRecords {
    /// One row per ID, keeping the input order of each ID's first appearance.
    static func unique<T: SyncedRecord>(_ records: [T]) -> [T] {
        var best: [UUID: T] = [:]
        var order: [UUID] = []
        for record in records {
            if let current = best[record.id] {
                if isNewer(record, than: current) { best[record.id] = record }
            } else {
                best[record.id] = record
                order.append(record.id)
            }
        }
        return order.compactMap { best[$0] }
    }

    static func isNewer<T: SyncedRecord>(_ a: T, than b: T) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.syncTieBreaker > b.syncTieBreaker
    }
}

extension FridgeRecord: SyncedRecord {
    var syncTieBreaker: String { "\(name)|\(templateID)|\(lastDoorStateRaw)|\(layoutData.base64EncodedString())" }
}

extension FoodItemRecord: SyncedRecord {
    var syncTieBreaker: String {
        "\(consumedAt?.timeIntervalSinceReferenceDate ?? -1)|\(quantityText)|\(name)|\(compartmentID)|\(fridgeID)"
    }
}

extension MagnetRecord: SyncedRecord {
    var syncTieBreaker: String { "\(zIndex)|\(centerX)|\(centerY)|\(width)|\(rotation)|\(styleRaw ?? "")|\(fridgeID)" }
}

/// Deleting magnets together with photos nobody else uses (same context, so it's part of the caller's save).
enum MagnetRecordCleanup {
    static func deleteMagnets(ofFridge fridgeID: UUID, in context: ModelContext) throws {
        let removed = try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let candidates = Set(removed.compactMap(\.localImageID))
        for magnet in removed { context.delete(magnet) }
        try deleteImages(candidates, stillUsedBy: try context.fetch(FetchDescriptor<MagnetRecord>())
            .filter { $0.fridgeID != fridgeID }, in: context)
    }

    /// Deletes the image records in `candidates` that none of `remaining` refers to. Only images that a deleted
    /// magnet *on this device* used are ever candidates: an image that arrived before its magnets is never touched.
    static func deleteImages(_ candidates: Set<UUID>, stillUsedBy remaining: [MagnetRecord], in context: ModelContext) throws {
        let stillUsed = Set(remaining.compactMap(\.localImageID))
        for id in candidates.subtracting(stillUsed) {
            for image in try context.fetch(FetchDescriptor<MagnetImageRecord>(predicate: #Predicate { $0.id == id })) {
                context.delete(image)
            }
        }
    }
}
