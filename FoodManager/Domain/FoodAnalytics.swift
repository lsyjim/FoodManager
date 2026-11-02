import Foundation

// Phase 5G: the food calendar and statistics, computed from persisted food records only (never mock data, never
// quantities summed across units, nothing written back). Pure functions over `FoodItem`s, so screens stay thin and
// every rule is unit tested. Day boundaries come from the given calendar (the user's calendar / time zone).

// MARK: - Calendar events

enum FoodEventKind: Int, CaseIterable, Comparable {
    case expiration
    case storageReminder
    case stored

    static func < (a: FoodEventKind, b: FoodEventKind) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .expiration: return "到期日"
        case .storageReminder: return "保存提醒"
        case .stored: return "放入冰箱"
        }
    }
}

struct FoodCalendarEvent: Equatable {
    let kind: FoodEventKind
    let item: FoodItem
    /// Start of the event's calendar day.
    let day: Date
    /// Consumed food: a past record, never an active reminder.
    var isHistorical: Bool { !item.isActive }
}

/// Which fridges and which temperature zone the calendar / statistics cover.
struct FoodAnalyticsScope: Equatable {
    var fridgeIDs: Set<UUID>
    var storage: StorageFilter = .all
}

/// The records the analytics look at, read once per screen (and again after a change).
struct FoodAnalyticsData {
    /// Active and consumed food of every fridge in scope.
    var items: [FoodItem]
    var compartments: [UUID: Compartment]
    var fridgeNames: [UUID: String]

    func filtered(_ scope: FoodAnalyticsScope) -> [FoodItem] {
        items.filter { scope.fridgeIDs.contains($0.fridgeID) && scope.storage.includes(compartments[$0.compartmentID]?.storageType) }
    }

    /// e.g. "我的冰箱 · 冷藏 · 上層" (fridge only when several are shown).
    func location(of item: FoodItem, showFridge: Bool) -> String {
        let place = compartments[item.compartmentID].map(CompartmentNaming.location)
        return ([showFridge ? fridgeNames[item.fridgeID] : nil, place].compactMap { $0 }).joined(separator: " · ")
    }
}

struct FoodCalendarModel {
    var calendar: Calendar = .current

    /// The dates of the month grid containing `month`: whole weeks (starting on the calendar's first weekday),
    /// `nil` for the leading / trailing cells outside the month. Always a multiple of 7.
    func monthGrid(for month: Date) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let first = interval.start
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<days.count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    func startOfMonth(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    func month(_ month: Date, offsetBy months: Int) -> Date {
        startOfMonth(calendar.date(byAdding: .month, value: months, to: startOfMonth(month)) ?? month)
    }

    /// The events of one food:
    /// - stored: its `storedAt` day (also for consumed food, marked historical);
    /// - expiration: its own `expirationDate` day, once (never repeated after expiry) — active food only;
    /// - storage reminder: `storedAt` + the item's own `storageReminderDays` calendar days (the day the reminder
    ///   becomes due under `FoodReminderEvaluator`) — active food only.
    func events(for item: FoodItem) -> [FoodCalendarEvent] {
        var events = [FoodCalendarEvent(kind: .stored, item: item, day: calendar.startOfDay(for: item.storedAt))]
        guard item.isActive else { return events }
        if let expiration = item.expirationDate {
            events.append(FoodCalendarEvent(kind: .expiration, item: item, day: calendar.startOfDay(for: expiration)))
        }
        if let days = item.storageReminderDays,
           let due = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: item.storedAt)) {
            events.append(FoodCalendarEvent(kind: .storageReminder, item: item, day: due))
        }
        return events
    }

    /// Events falling inside `month`, by day. Each food contributes each kind at most once.
    func eventsByDay(items: [FoodItem], month: Date) -> [Date: [FoodCalendarEvent]] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var result: [Date: [FoodCalendarEvent]] = [:]
        for item in items {
            for event in events(for: item) where interval.contains(event.day) {
                result[event.day, default: []].append(event)
            }
        }
        return result.mapValues(Self.sorted)
    }

    /// Expiration first, then storage reminders, then stored food; active before history; then by name.
    static func sorted(_ events: [FoodCalendarEvent]) -> [FoodCalendarEvent] {
        events.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if a.isHistorical != b.isHistorical { return !a.isHistorical }
            let byName = a.item.name.localizedStandardCompare(b.item.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.item.id.uuidString < b.item.id.uuidString
        }
    }

    /// Distinct kinds on a day (for the dots), in display order.
    static func kinds(_ events: [FoodCalendarEvent]?) -> [FoodEventKind] {
        Array(Set((events ?? []).map(\.kind))).sorted()
    }
}

// MARK: - Statistics

enum StatisticsPeriod: CaseIterable, Equatable {
    case week
    case month
    case halfYear

    var title: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .halfYear: return "近 6 個月"
        }
    }
}

struct InventorySummary: Equatable {
    var active = 0
    var expired = 0
    var expiringSoon = 0
    /// Food marked eaten within the selected period.
    var consumedInPeriod = 0
}

struct ActivityBucket: Equatable {
    /// Start of the day or month.
    let start: Date
    let label: String
    var added: Int
    var consumed: Int
}

struct CategoryShare: Equatable {
    let category: FoodCategory
    let count: Int
    /// 0…1; all shares add up to 1.
    let fraction: Double
}

struct FoodStatistics {
    var calendar: Calendar = .current
    var evaluator = FoodReminderEvaluator()

    /// The period's buckets, oldest first: 7 or 30 days ending today, or 6 months ending this month.
    func buckets(_ period: StatisticsPeriod, now: Date) -> [ActivityBucket] {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .week, .month:
            let count = period == .week ? 7 : 30
            return (0..<count).reversed().compactMap { back in
                calendar.date(byAdding: .day, value: -back, to: today).map {
                    ActivityBucket(start: $0, label: Self.dayLabel($0, calendar: calendar), added: 0, consumed: 0)
                }
            }
        case .halfYear:
            let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
            return (0..<6).reversed().compactMap { back in
                calendar.date(byAdding: .month, value: -back, to: thisMonth).map {
                    ActivityBucket(start: $0, label: "\(calendar.component(.month, from: $0))月", added: 0, consumed: 0)
                }
            }
        }
    }

    /// New food records (by `storedAt`) and food marked eaten (by `consumedAt`) per bucket. A quantity change is
    /// never counted as consumption.
    func activity(items: [FoodItem], period: StatisticsPeriod, now: Date) -> [ActivityBucket] {
        var buckets = buckets(period, now: now)
        guard let first = buckets.first?.start else { return buckets }
        let component: Calendar.Component = period == .halfYear ? .month : .day
        func index(of date: Date) -> Int? {
            let start = calendar.dateInterval(of: component, for: date)?.start ?? date
            guard start >= first else { return nil }
            return buckets.firstIndex { $0.start == start }
        }
        for item in items {
            if let i = index(of: item.storedAt) { buckets[i].added += 1 }
            if let consumed = item.consumedAt, let i = index(of: consumed) { buckets[i].consumed += 1 }
        }
        return buckets
    }

    func periodInterval(_ period: StatisticsPeriod, now: Date) -> DateInterval? {
        let buckets = buckets(period, now: now)
        guard let start = buckets.first?.start, let last = buckets.last?.start,
              let end = calendar.date(byAdding: period == .halfYear ? .month : .day, value: 1, to: last) else { return nil }
        return DateInterval(start: start, end: end)
    }

    func summary(items: [FoodItem], period: StatisticsPeriod, now: Date) -> InventorySummary {
        var summary = InventorySummary()
        let interval = periodInterval(period, now: now)
        for item in items {
            if item.isActive {
                summary.active += 1
                switch evaluator.expirationStatus(of: item, now: now) {
                case .expired: summary.expired += 1
                case .expiringSoon: summary.expiringSoon += 1
                case .none, .fresh: break
                }
            } else if let consumed = item.consumedAt, interval?.contains(consumed) == true {
                summary.consumedInPeriod += 1
            }
        }
        return summary
    }

    /// Active food records per category (counts, never quantities). Unknown legacy categories count as 其他, like
    /// everywhere else in the app. Largest first; ties in catalog order.
    func categoryShares(items: [FoodItem]) -> [CategoryShare] {
        let active = items.filter(\.isActive)
        guard !active.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for item in active { counts[FoodCategoryCatalog.category(id: item.categoryID).id, default: 0] += 1 }
        let order = Dictionary(uniqueKeysWithValues: FoodCategoryCatalog.all.enumerated().map { ($1.id, $0) })
        let total = Double(active.count)
        return counts.map { CategoryShare(category: FoodCategoryCatalog.category(id: $0.key), count: $0.value, fraction: Double($0.value) / total) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : (order[$0.category.id] ?? 0) < (order[$1.category.id] ?? 0) }
    }

    /// Average calendar days between storing and marking eaten, over consumed records in the period with a valid
    /// pair (eaten on or after storing). A record of what happened — not a shelf-life or food-safety figure.
    func averageStorageDays(items: [FoodItem], period: StatisticsPeriod, now: Date) -> Double? {
        let interval = periodInterval(period, now: now)
        let dates = FoodDateCalculator(calendar: calendar)
        let days = items.compactMap { item -> Int? in
            guard let consumed = item.consumedAt, consumed >= item.storedAt, interval?.contains(consumed) == true else { return nil }
            return dates.daysStored(since: item.storedAt, now: consumed)
        }
        guard !days.isEmpty else { return nil }
        return Double(days.reduce(0, +)) / Double(days.count)
    }

    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }
}

// MARK: - Loading

enum FoodAnalyticsLoadError: Error, Equatable {
    case unreadable
}

/// Reads the records for the analytics from the session's stores (personal and, when enabled, shared fridges the
/// user may read — through the same routing stores as every other screen). A failed read is an error, never an
/// empty calendar.
struct FoodAnalyticsLoader {
    let directory: FridgeDirectory
    let foodStore: FoodStore

    func load() throws -> FoodAnalyticsData {
        let fridges = directory.fridges
        var items: [FoodItem] = []
        do {
            for fridge in fridges {
                items += try foodStore.activeItems(fridgeID: fridge.id)
                items += try foodStore.consumedItems(fridgeID: fridge.id)
            }
        } catch {
            throw FoodAnalyticsLoadError.unreadable
        }
        var seen = Set<UUID>()
        items = items.filter { seen.insert($0.id).inserted }
        let compartments = Dictionary(fridges.flatMap(\.allCompartments).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FoodAnalyticsData(items: items, compartments: compartments,
                                 fridgeNames: Dictionary(fridges.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }
}
