import Foundation

// Notifications are only a delivery mechanism. The source of truth is persisted food + the same
// `FoodReminderEvaluator`/`FoodDateCalculator` rules used by the reminder center and dashboard.

extension Notification.Name {
    static let notificationPreferencesDidChange = Notification.Name("NotificationPreferencesDidChange")
}

/// User-configurable notification behaviour (stored locally).
struct NotificationPreferences: Codable, Equatable {
    var expirationRemindersEnabled = true
    var storageRemindersEnabled = true
    /// Daily delivery time in the user's local time zone.
    var reminderHour = 9
    var reminderMinute = 0
    /// Calendar days before the expiration date to notify (0 = on the day).
    var expirationLeadDays = 1
    /// Whether the contextual "turn on notifications?" explanation was already shown.
    var hasShownPermissionPrompt = false

    static let leadDayRange = 0...7
}

protocol NotificationPreferencesStore: AnyObject {
    func load() -> NotificationPreferences
    func save(_ preferences: NotificationPreferences)
}

final class UserDefaultsNotificationPreferencesStore: NotificationPreferencesStore {
    static let key = "notificationPreferences"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> NotificationPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let preferences = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { return .init() }
        return preferences
    }

    func save(_ preferences: NotificationPreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.key)
        NotificationCenter.default.post(name: .notificationPreferencesDidChange, object: self)
    }
}

/// System permission, reduced to what the app needs to know.
enum NotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var canSchedule: Bool { self == .authorized || self == .provisional || self == .ephemeral }
}

enum NotificationKind: String, Equatable {
    case expiration
    case storage
}

/// A notification the app wants pending. `fireDate` is local calendar components (not a fixed offset),
/// so daylight-saving changes keep the 09:00 delivery at 09:00 local time.
struct PlannedNotification: Equatable {
    static let identifierPrefix = "food."

    let foodID: UUID
    let kind: NotificationKind
    let fireDate: DateComponents
    let title: String
    let body: String

    /// Stable per food and type: re-adding replaces instead of duplicating.
    var identifier: String { Self.identifier(foodID: foodID, kind: kind) }

    static func identifier(foodID: UUID, kind: NotificationKind) -> String {
        "\(identifierPrefix)\(foodID.uuidString).\(kind.rawValue)"
    }

    /// Parses an identifier produced by `identifier(foodID:kind:)`.
    static func foodID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let rest = identifier.dropFirst(identifierPrefix.count)
        return UUID(uuidString: String(rest.prefix(36)))
    }
}

enum NotificationPayload {
    static let foodIDKey = "foodID"
    static let kindKey = "kind"

    static func userInfo(for planned: PlannedNotification) -> [String: String] {
        [foodIDKey: planned.foodID.uuidString, kindKey: planned.kind.rawValue]
    }

    static func foodID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[foodIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Pure scheduling rules (unit-tested without the system notification center).
///
/// - Expiration: only when an expiration date exists. Fires `expirationLeadDays` calendar days before it at
///   the reminder time. If that moment already passed but the food hasn't expired yet, fires at the next
///   reminder time (as long as that is still on or before the expiration day). Already-expired food gets
///   no notification; it is listed in the reminder center.
/// - Storage: fires on the day `storedAt + storageReminderDays` at the reminder time. If that moment already
///   passed, nothing is scheduled (the reminder center already shows it).
/// - Bounded: at most `maxPending` notifications, soonest first (iOS keeps only 64 pending per app).
struct NotificationPlanner {
    static let maxPending = 60

    var calendar: Calendar = .current

    func plan(items: [FoodItem], compartments: [Compartment], preferences: NotificationPreferences,
              now: Date) -> [PlannedNotification] {
        let locations = Dictionary(compartments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var planned: [(date: Date, notification: PlannedNotification)] = []
        for item in items where item.isActive {
            let place = locations[item.compartmentID].map { "（\(CompartmentNaming.location($0))）" } ?? ""
            if preferences.expirationRemindersEnabled, let entry = expiration(for: item, place: place, preferences: preferences, now: now) {
                planned.append(entry)
            }
            if preferences.storageRemindersEnabled, let entry = storage(for: item, place: place, preferences: preferences, now: now) {
                planned.append(entry)
            }
        }
        return planned
            .sorted { ($0.date, $0.notification.identifier) < ($1.date, $1.notification.identifier) }
            .prefix(Self.maxPending)
            .map(\.notification)
    }

    private func expiration(for item: FoodItem, place: String, preferences: NotificationPreferences,
                            now: Date) -> (date: Date, notification: PlannedNotification)? {
        guard let expiration = item.expirationDate else { return nil }
        let expirationDay = calendar.startOfDay(for: expiration)
        guard let leadDay = calendar.date(byAdding: .day, value: -preferences.expirationLeadDays, to: expirationDay),
              var fire = reminderTime(on: leadDay, preferences) else { return nil }
        if fire <= now {
            guard let next = nextReminderTime(after: now, preferences),
                  calendar.startOfDay(for: next) <= expirationDay else { return nil }
            fire = next
        }
        let daysLeft = FoodDateCalculator(calendar: calendar).daysUntilExpiration(expiration, now: fire)
        let when = FoodFormatting.expirationText(.expiringSoon(daysLeft: max(0, daysLeft))) ?? ""
        return (fire, PlannedNotification(foodID: item.id, kind: .expiration, fireDate: components(fire),
                                          title: "食材即將到期", body: "「\(item.name)」\(place)\(when)"))
    }

    private func storage(for item: FoodItem, place: String, preferences: NotificationPreferences,
                         now: Date) -> (date: Date, notification: PlannedNotification)? {
        guard let days = item.storageReminderDays,
              let dueDay = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: item.storedAt)),
              let fire = reminderTime(on: dueDay, preferences), fire > now else { return nil }
        return (fire, PlannedNotification(foodID: item.id, kind: .storage, fireDate: components(fire),
                                          title: "保存提醒", body: "「\(item.name)」\(place)已存放 \(days) 天，記得確認狀態"))
    }

    private func reminderTime(on day: Date, _ preferences: NotificationPreferences) -> Date? {
        calendar.date(bySettingHour: preferences.reminderHour, minute: preferences.reminderMinute, second: 0,
                      of: calendar.startOfDay(for: day))
    }

    private func nextReminderTime(after now: Date, _ preferences: NotificationPreferences) -> Date? {
        guard let today = reminderTime(on: now, preferences) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)).flatMap { reminderTime(on: $0, preferences) }
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
