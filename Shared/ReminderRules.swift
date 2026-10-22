import Foundation

// Shared by the app and the widget extension (no UIKit / app-only types).
// Storage classification is always derived FoodItem → Compartment → StorageType.

/// How the user classifies a compartment of their physical fridge. The app never controls real temperature,
/// and this value never influences where a compartment sits — only the user's order does.
enum StorageType: String, Codable, CaseIterable {
    case refrigerated
    case frozen
    case unspecified

    var displayName: String {
        switch self {
        case .refrigerated: return "冷藏"
        case .frozen: return "冷凍"
        case .unspecified: return "未分類"
        }
    }
}

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

/// The only fields reminder rules look at. `FoodItem` (app) and `WidgetSnapshot.Item` (widget) conform,
/// so the reminder center, dashboard, notifications and widgets all share one implementation.
protocol ReminderSubject {
    var storedAt: Date { get }
    var expirationDate: Date? { get }
    var storageReminderDays: Int? { get }
}

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

    func expirationStatus(of item: some ReminderSubject, now: Date) -> ExpirationStatus {
        guard let expiration = item.expirationDate else { return .none }
        let days = dates.daysUntilExpiration(expiration, now: now)
        if days < 0 { return .expired(daysAgo: -days) }
        if days <= policy.expiringSoonDays { return .expiringSoon(daysLeft: days) }
        return .fresh(daysLeft: days)
    }

    func isStorageReminderDue(_ item: some ReminderSubject, now: Date) -> Bool {
        guard let limit = item.storageReminderDays else { return false }
        return dates.daysStored(since: item.storedAt, now: now) >= limit
    }

    func reminders(for item: some ReminderSubject, now: Date) -> Set<FoodReminderKind> {
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

/// Which reminder type the reminder center shows.
enum ReminderKindFilter: CaseIterable, Equatable {
    case all
    case expiringSoon
    case expired
    case storedTooLong

    var title: String {
        switch self {
        case .all: return "全部提醒"
        case .expiringSoon: return "即將到期"
        case .expired: return "已過期"
        case .storedTooLong: return "保存提醒"
        }
    }

    func matches(_ kinds: Set<FoodReminderKind>) -> Bool {
        switch self {
        case .all: return !kinds.isEmpty
        case .expiringSoon: return kinds.contains(.expiringSoon)
        case .expired: return kinds.contains(.expired)
        case .storedTooLong: return kinds.contains(.storedTooLong)
        }
    }
}


/// Ordering shared by the reminder center and widgets: expired (longest ago first), then expiring soon
/// (soonest first), then storage reminders (most overdue first).
enum ReminderUrgency {
    static func key(expiration: ExpirationStatus, daysStored: Int, storageReminderDays: Int?) -> (rank: Int, value: Int) {
        switch expiration {
        case let .expired(daysAgo): return (0, -daysAgo)
        case let .expiringSoon(daysLeft): return (1, daysLeft)
        case .fresh, .none: return (2, -(daysStored - (storageReminderDays ?? 0)))
        }
    }
}
