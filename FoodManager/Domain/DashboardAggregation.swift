import Foundation

// Storage classification is always derived FoodItem → Compartment → StorageType; it is never copied onto FoodItem,
// so moving food to another compartment (or reclassifying a compartment) re-classifies it automatically.

/// Which slice of the fridge the dashboard summarizes.
enum StorageFilter: CaseIterable {
    case all
    case refrigerated
    case frozen

    var title: String {
        switch self {
        case .all: return "全部"
        case .refrigerated: return StorageType.refrigerated.displayName
        case .frozen: return StorageType.frozen.displayName
        }
    }

    /// `storage` is nil when the food's compartment can't be found. Unspecified (door) and unknown
    /// locations only count under `.all` — they are never dropped from the overall total.
    func includes(_ storage: StorageType?) -> Bool {
        switch self {
        case .all: return true
        case .refrigerated: return storage == .refrigerated
        case .frozen: return storage == .frozen
        }
    }
}

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

// MARK: - Calendar-day maths

/// All day counts are calendar days in the user's calendar/time zone (never seconds / 86400).
struct FoodDateCalculator {
    var calendar: Calendar = .current

    /// Calendar days since the item was stored; 0 on the day it was stored (future dates clamp to 0).
    func daysStored(since storedAt: Date, now: Date) -> Int {
        max(0, dayDifference(from: storedAt, to: now))
    }

    /// Calendar days until expiration: 0 = today, 1 = tomorrow, negative = expired that many days ago.
    func daysUntilExpiration(_ expiration: Date, now: Date) -> Int {
        dayDifference(from: now, to: expiration)
    }

    private func dayDifference(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}

enum ExpirationStatus: Equatable {
    case none
    case fresh(daysLeft: Int)
    case expiringSoon(daysLeft: Int)
    case expired(daysAgo: Int)
}

// MARK: - Reminders

enum FoodReminderKind: Hashable {
    case expiringSoon
    case expired
    case storedTooLong
}

struct ReminderPolicy: Equatable {
    /// "Expiring soon" = expiration between today and this many calendar days ahead, inclusive.
    var expiringSoonDays: Int

    static let standard = ReminderPolicy(expiringSoonDays: 3)
}

/// Expiry reminders come only from a user-entered `expirationDate`; storage reminders come only from
/// `storedAt` + the item's own `storageReminderDays`. The two are independent and never inferred.
struct FoodReminderEvaluator {
    var policy: ReminderPolicy = .standard
    var calendar: Calendar = .current

    private var dates: FoodDateCalculator { FoodDateCalculator(calendar: calendar) }

    func expirationStatus(of item: FoodItem, now: Date) -> ExpirationStatus {
        guard let expiration = item.expirationDate else { return .none }
        let days = dates.daysUntilExpiration(expiration, now: now)
        if days < 0 { return .expired(daysAgo: -days) }
        if days <= policy.expiringSoonDays { return .expiringSoon(daysLeft: days) }
        return .fresh(daysLeft: days)
    }

    func isStorageReminderDue(_ item: FoodItem, now: Date) -> Bool {
        guard let limit = item.storageReminderDays else { return false }
        return dates.daysStored(since: item.storedAt, now: now) >= limit
    }

    func reminders(for item: FoodItem, now: Date) -> Set<FoodReminderKind> {
        var result = Set<FoodReminderKind>()
        switch expirationStatus(of: item, now: now) {
        case .expired: result.insert(.expired)
        case .expiringSoon: result.insert(.expiringSoon)
        case .none, .fresh: break
        }
        if isStorageReminderDue(item, now: now) { result.insert(.storedTooLong) }
        return result
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
