import Foundation
import WidgetKit
import os

/// Builds the widget snapshot from persisted inventory using the shared reminder rules.
enum WidgetSnapshotBuilder {
    static func build(fridge: Fridge, items: [FoodItem], now: Date,
                      evaluator: FoodReminderEvaluator = FoodReminderEvaluator()) -> WidgetSnapshot {
        let compartments = Dictionary(fridge.allCompartments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let active = items.filter(\.isActive)
        let candidates = active
            .filter { $0.expirationDate != nil || $0.storageReminderDays != nil }
            .map { item -> (date: Date, item: WidgetSnapshot.Item) in
                let compartment = compartments[item.compartmentID]
                let storageDue = item.storageReminderDays.flatMap {
                    evaluator.calendar.date(byAdding: .day, value: $0, to: evaluator.calendar.startOfDay(for: item.storedAt))
                }
                let relevant = [item.expirationDate, storageDue].compactMap { $0 }.min() ?? .distantFuture
                return (relevant, WidgetSnapshot.Item(
                    id: item.id, name: item.name,
                    categoryAssetName: FoodCategoryCatalog.category(id: item.categoryID).assetName,
                    locationName: compartment.map(CompartmentNaming.location), storage: compartment?.storageType,
                    storedAt: item.storedAt, expirationDate: item.expirationDate, storageReminderDays: item.storageReminderDays))
            }
            .sorted { ($0.date, $0.item.id.uuidString) < ($1.date, $1.item.id.uuidString) }

        let kept = candidates.prefix(WidgetSnapshot.maxItems).map(\.item)
        let today = WidgetReminderSummary(items: Array(kept), now: now, evaluator: evaluator)
        return WidgetSnapshot(
            snapshotVersion: WidgetSnapshot.currentVersion, generatedAt: now,
            refrigeratorID: fridge.id, refrigeratorName: fridge.name, activeFoodCount: active.count,
            refrigeratedReminderCount: today.refrigeratedCount, frozenReminderCount: today.frozenCount,
            unspecifiedReminderCount: today.unspecifiedCount, expiredCount: today.expiredCount,
            expiringSoonCount: today.expiringSoonCount, storageReminderCount: today.storageReminderCount,
            urgentFoodItems: Array(kept), isTruncated: candidates.count > kept.count)
    }
}

/// Abstraction over `WidgetCenter` so tests can count reloads.
protocol WidgetReloading {
    func reloadAll()
}

struct SystemWidgetReloader: WidgetReloading {
    func reloadAll() { WidgetCenter.shared.reloadAllTimelines() }
}

/// Writes snapshots off the main thread and asks WidgetKit to reload only when the visible content
/// changed (WidgetKit still decides the actual refresh time). Callers must only publish after a
/// successful persisted change or a successful read — never from a failed operation.
final class WidgetSnapshotPublisher {
    private let file: WidgetSnapshotFile?
    private let reloader: WidgetReloading
    private let queue = DispatchQueue(label: "FoodManager.WidgetSnapshot", qos: .utility)
    private let calendar: Calendar
    private var lastContentKey: Data?
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Widget")

    init(file: WidgetSnapshotFile? = .shared, reloader: WidgetReloading = SystemWidgetReloader(), calendar: Calendar = .current) {
        self.file = file
        self.reloader = reloader
        self.calendar = calendar
        if file == nil { logger.error("App Group container unavailable; widgets cannot be updated") }
    }

    /// Publishes every fridge (food is split by `fridgeID`, so nothing shows under the wrong fridge).
    func publish(fridges: [Fridge], items: [FoodItem], selectedFridgeID: UUID, now: Date = Date()) {
        guard let file, !fridges.isEmpty else { return }
        queue.async { [self] in
            let bundle = WidgetSnapshotBundle(
                bundleVersion: WidgetSnapshotBundle.currentVersion, generatedAt: now, selectedFridgeID: selectedFridgeID,
                fridges: fridges.map { fridge in
                    WidgetSnapshotBuilder.build(fridge: fridge, items: items.filter { $0.fridgeID == fridge.id }, now: now)
                })
            do {
                // Same content on the same day → nothing to do (avoids needless widget reloads).
                var keyed = bundle
                let day = calendar.startOfDay(for: now)
                keyed.generatedAt = day
                for index in keyed.fridges.indices { keyed.fridges[index].generatedAt = day }
                let key = try WidgetSnapshotFile.encode(keyed)
                guard key != lastContentKey || file.read() == nil else { return }
                try file.write(WidgetSnapshotFile.encode(bundle))
                lastContentKey = key
                DispatchQueue.main.async { self.reloader.reloadAll() }
            } catch {
                logger.error("Writing widget snapshot failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Blocks until queued writes finish (tests).
    func waitUntilIdle() { queue.sync {} }
}
