import Foundation

/// App Group shared by the app and the widget extension. The widget only ever *reads* the snapshot file;
/// it never opens or writes the app's SwiftData inventory database.
enum AppGroup {
    static let identifier = "group.FoodManager.HowCode"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// The minimal data a widget needs, written by the app after successful changes.
///
/// Counts depend on the calendar day, so besides the counts "as of `generatedAt`" the snapshot carries
/// the few reminder-relevant fields of each food that *can* trigger a reminder. The widget recomputes
/// counts for each timeline day with the same `FoodReminderEvaluator` the app uses, so reminders stay
/// correct for days even if the app isn't opened.
struct WidgetSnapshot: Codable, Equatable {
    static let currentVersion = 1
    /// Upper bound of reminder candidates stored (soonest relevant date first).
    static let maxItems = 300

    struct Item: Codable, Equatable, Identifiable, ReminderSubject {
        let id: UUID
        let name: String
        /// Bundled illustration name (no image data is ever shared).
        let categoryAssetName: String
        /// e.g. "櫃內 · 上層"; nil when the compartment no longer exists.
        let locationName: String?
        /// nil when the compartment no longer exists (then counted under 全部 only).
        let storage: StorageType?
        let storedAt: Date
        let expirationDate: Date?
        let storageReminderDays: Int?
    }

    var snapshotVersion: Int
    var generatedAt: Date
    var refrigeratorID: UUID
    var refrigeratorName: String
    var activeFoodCount: Int
    // Counts as of `generatedAt` (one per food; a food with several statuses counts once per storage bucket).
    var refrigeratedReminderCount: Int
    var frozenReminderCount: Int
    var unspecifiedReminderCount: Int
    var expiredCount: Int
    var expiringSoonCount: Int
    var storageReminderCount: Int
    /// Foods with an expiration date or storage reminder (the only ones that can ever need attention).
    var urgentFoodItems: [Item]
    /// True when more candidates existed than `maxItems`.
    var isTruncated: Bool

    /// Reminder state on a given day, using the shared business rules.
    func summary(at date: Date, evaluator: FoodReminderEvaluator = FoodReminderEvaluator()) -> WidgetReminderSummary {
        WidgetReminderSummary(items: urgentFoodItems, now: date, evaluator: evaluator)
    }
}

/// What the app writes to the App Group: one snapshot per fridge plus the fridge selected in the app.
/// Widgets configured for a specific fridge show that one; otherwise they follow the app's selection.
struct WidgetSnapshotBundle: Codable, Equatable {
    static let currentVersion = 2

    var bundleVersion: Int
    var generatedAt: Date
    var selectedFridgeID: UUID
    var fridges: [WidgetSnapshot]

    /// The configured fridge if it still exists, else the app's selected fridge, else the first one
    /// (a deleted fridge never shows stale food).
    func snapshot(for fridgeID: UUID?) -> WidgetSnapshot? {
        if let fridgeID, let match = fridges.first(where: { $0.refrigeratorID == fridgeID }) { return match }
        return fridges.first { $0.refrigeratorID == selectedFridgeID } ?? fridges.first
    }
}

/// Counts and an urgency-ordered list for one day. A food appears once even with several statuses.
struct WidgetReminderSummary: Equatable {
    struct Entry: Equatable, Identifiable {
        let item: WidgetSnapshot.Item
        let kinds: Set<FoodReminderKind>
        let expiration: ExpirationStatus
        let daysStored: Int
        var id: UUID { item.id }

        /// The single most important status (expiry first, then storage duration).
        var primaryStatus: String {
            if kinds.contains(.expired) || kinds.contains(.expiringSoon),
               let text = FoodFormatting.expirationText(expiration) { return text }
            return FoodFormatting.storageText(daysStored: daysStored)
        }
    }

    let entries: [Entry]
    var attentionCount: Int { entries.count }
    var refrigeratedCount: Int { entries.filter { $0.item.storage == .refrigerated }.count }
    var frozenCount: Int { entries.filter { $0.item.storage == .frozen }.count }
    var unspecifiedCount: Int { entries.filter { $0.item.storage != .refrigerated && $0.item.storage != .frozen }.count }
    var expiredCount: Int { entries.filter { $0.kinds.contains(.expired) }.count }
    var expiringSoonCount: Int { entries.filter { $0.kinds.contains(.expiringSoon) }.count }
    var storageReminderCount: Int { entries.filter { $0.kinds.contains(.storedTooLong) }.count }

    init(items: [WidgetSnapshot.Item], now: Date, evaluator: FoodReminderEvaluator) {
        let dates = FoodDateCalculator(calendar: evaluator.calendar)
        entries = items.compactMap { item -> Entry? in
            let kinds = evaluator.reminders(for: item, now: now)
            guard !kinds.isEmpty else { return nil }
            return Entry(item: item, kinds: kinds, expiration: evaluator.expirationStatus(of: item, now: now),
                         daysStored: dates.daysStored(since: item.storedAt, now: now))
        }
        .sorted { a, b in
            let ka = ReminderUrgency.key(expiration: a.expiration, daysStored: a.daysStored, storageReminderDays: a.item.storageReminderDays)
            let kb = ReminderUrgency.key(expiration: b.expiration, daysStored: b.daysStored, storageReminderDays: b.item.storageReminderDays)
            if ka.rank != kb.rank { return ka.rank < kb.rank }
            if ka.value != kb.value { return ka.value < kb.value }
            let byName = a.item.name.localizedStandardCompare(b.item.name)
            return byName == .orderedSame ? a.item.id.uuidString < b.item.id.uuidString : byName == .orderedAscending
        }
    }

    func entries(_ kind: FoodReminderKind) -> [Entry] { entries.filter { $0.kinds.contains(kind) } }
}

/// Reads/writes the snapshot JSON file inside the App Group container.
struct WidgetSnapshotFile {
    static let fileName = "widget-snapshot.json"
    let url: URL

    /// nil when the App Group container is unavailable (e.g. entitlement missing).
    static var shared: WidgetSnapshotFile? {
        AppGroup.containerURL.map { WidgetSnapshotFile(url: $0.appendingPathComponent(fileName)) }
    }

    /// Missing, unreadable, malformed, old single-fridge (v1) or future-version files all yield nil (the
    /// widget then shows an "open the app" state instead of wrong numbers; the app rewrites it on launch).
    func read() -> WidgetSnapshotBundle? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> WidgetSnapshotBundle? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let bundle = try? decoder.decode(WidgetSnapshotBundle.self, from: data),
              bundle.bundleVersion == WidgetSnapshotBundle.currentVersion,
              bundle.fridges.allSatisfy({ $0.snapshotVersion == WidgetSnapshot.currentVersion }) else { return nil }
        return bundle
    }

    static func encode(_ bundle: WidgetSnapshotBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bundle)
    }

    /// Atomic replace, so the widget never reads a half-written file.
    func write(_ data: Data) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
