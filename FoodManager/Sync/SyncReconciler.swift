import Foundation
import SwiftData

/// Keeps the synced data consistent after records arrive from iCloud (in any order). It never assigns food to a
/// fridge or compartment on its own and never deletes anything the user made; problems it can't fix safely are
/// reported so the user can resolve them (管理冰箱 → 需要處理).
struct SyncReconciler {
    struct Report: Equatable {
        /// The empty, untouched default fridge of a new install was removed because older fridges arrived.
        var removedPlaceholderFridge = false
        /// More fridges than `FridgePolicy` allows (two devices created fridges before syncing).
        var fridgeCount = 0
        /// Active food whose fridge isn't on this device (not arrived yet, or deleted elsewhere).
        var unplacedFoodCount = 0

        var exceedsFridgeLimit: Bool { fridgeCount > FridgePolicy.maxRefrigerators }
        var needsAttention: Bool { exceedsFridgeLimit || unplacedFoodCount > 0 }
    }

    let container: ModelContainer

    @discardableResult
    func run() throws -> Report {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var report = Report()
        var fridges = SyncedRecords.unique(try context.fetch(FetchDescriptor<FridgeRecord>()))

        // A brand-new install creates "我的冰箱" with fixed IDs before its iCloud data arrives. Once fridges that
        // existed *before* it show up, the placeholder is removed — but only if nobody ever used it: never renamed
        // or edited, no food or history, no magnets. A fridge the user created on this device is never touched.
        let placeholderID = FridgeFactory.firstLaunchFridgeID
        if let placeholder = fridges.first(where: { $0.id == placeholderID }),
           fridges.contains(where: { $0.id != placeholderID && $0.createdAt < placeholder.createdAt }),
           placeholder.updatedAt == placeholder.createdAt,
           try context.fetchCount(FetchDescriptor<FoodItemRecord>(predicate: #Predicate { $0.fridgeID == placeholderID })) == 0,
           try context.fetchCount(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == placeholderID })) == 0 {
            for record in try context.fetch(FetchDescriptor<FridgeRecord>(predicate: #Predicate { $0.id == placeholderID })) {
                context.delete(record)
            }
            try context.save()
            fridges.removeAll { $0.id == placeholderID }
            report.removedPlaceholderFridge = true
        }

        report.fridgeCount = fridges.count
        let known = Set(fridges.map(\.id))
        report.unplacedFoodCount = SyncedRecords.unique(try context.fetch(FetchDescriptor<FoodItemRecord>()))
            .filter { $0.consumedAt == nil && !known.contains($0.fridgeID) }.count
        return report
    }

    /// Changes whenever any synced record changes (used to refresh the UI only when imported data differs).
    func fingerprint() throws -> String {
        let context = ModelContext(container)
        var parts: [String] = []
        for r in try context.fetch(FetchDescriptor<FridgeRecord>()) {
            parts.append("F\(r.id)\(r.updatedAt.timeIntervalSinceReferenceDate)\(r.lastDoorStateRaw)\(r.name)")
        }
        for r in try context.fetch(FetchDescriptor<FoodItemRecord>()) {
            parts.append("I\(r.id)\(r.updatedAt.timeIntervalSinceReferenceDate)\(r.consumedAt?.timeIntervalSinceReferenceDate ?? 0)\(r.fridgeID)")
        }
        for r in try context.fetch(FetchDescriptor<MagnetRecord>()) {
            parts.append("M\(r.id)\(r.updatedAt.timeIntervalSinceReferenceDate)")
        }
        for r in try context.fetch(FetchDescriptor<MagnetImageRecord>()) {
            parts.append("P\(r.id)\(r.data != nil)")
        }
        return CloudKitAccountProvider.hash(parts.sorted().joined())
    }
}
