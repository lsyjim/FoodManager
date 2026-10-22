import Foundation

// Storage classification is always derived FoodItem → Compartment → StorageType; it is never copied onto FoodItem,
// so moving food to another compartment (or reclassifying a compartment) re-classifies it automatically.

/// Totals shown beside the closed fridge. `nil` means "no data" and renders as a dash.
struct DashboardSummary: Equatable {
    var itemCount: Int?
    var expiringSoonCount: Int?
    var expiredCount: Int?
    /// Items whose storage reminder is due ("保存提醒").
    var reminderCount: Int?

    static let placeholder = DashboardSummary()
}

/// Source of dashboard numbers.
protocol DashboardSummaryProviding {
    func summary(for filter: StorageFilter) -> DashboardSummary
}

struct PlaceholderDashboardProvider: DashboardSummaryProviding {
    func summary(for filter: StorageFilter) -> DashboardSummary { .placeholder }
}

/// Dashboard numbers computed from a snapshot of the real inventory.
struct InventoryDashboardProvider: DashboardSummaryProviding {
    let items: [FoodItem]
    let compartments: [Compartment]
    let aggregator: DashboardAggregator
    let now: Date

    func summary(for filter: StorageFilter) -> DashboardSummary {
        aggregator.summary(items: items, compartments: compartments, filter: filter, now: now)
    }
}

// MARK: - Aggregation

/// Pure aggregation of active food records into dashboard totals, filtered by each item's compartment storage type.
struct DashboardAggregator {
    var evaluator = FoodReminderEvaluator()

    func summary(items: [FoodItem], compartments: [Compartment], filter: StorageFilter, now: Date) -> DashboardSummary {
        let storageByCompartment = Dictionary(compartments.map { ($0.id, $0.storageType) }, uniquingKeysWith: { a, _ in a })
        var summary = DashboardSummary(itemCount: 0, expiringSoonCount: 0, expiredCount: 0, reminderCount: 0)
        for item in items where item.isActive {
            guard filter.includes(storageByCompartment[item.compartmentID]) else { continue }
            let reminders = evaluator.reminders(for: item, now: now)
            summary.itemCount? += 1
            if reminders.contains(.expiringSoon) { summary.expiringSoonCount? += 1 }
            if reminders.contains(.expired) { summary.expiredCount? += 1 }
            if reminders.contains(.storedTooLong) { summary.reminderCount? += 1 }
        }
        return summary
    }
}
