import Foundation

/// One food needing attention. A food that is both expired and past its storage reminder is ONE entry
/// listing both statuses, never two rows.
struct ReminderEntry: Equatable {
    let item: FoodItem
    let compartment: Compartment?
    let kinds: Set<FoodReminderKind>
    let expiration: ExpirationStatus
    let daysStored: Int
    /// Set when reminders of several fridges are listed together, so every row shows where it lives.
    var fridgeName: String? = nil

    var locationText: String {
        let place = compartment.map(CompartmentNaming.location) ?? "位置不存在"
        return fridgeName.map { "\($0) · \(place)" } ?? place
    }

    /// e.g. ["已過期 1 天", "已存放 30 天"].
    var statusTexts: [String] {
        var texts: [String] = []
        if kinds.contains(.expired) || kinds.contains(.expiringSoon), let text = FoodFormatting.expirationText(expiration) {
            texts.append(text)
        }
        if kinds.contains(.storedTooLong) { texts.append(FoodFormatting.storageText(daysStored: daysStored)) }
        return texts
    }
}

/// Builds the reminder center from persisted inventory using the same evaluator as the dashboard,
/// so counts and lists can never disagree. Classification is derived FoodItem → Compartment → StorageType.
struct ReminderCenterBuilder {
    var evaluator = FoodReminderEvaluator()

    /// `fridgeNames` (all-fridges scope) labels each entry with its fridge.
    func entries(items: [FoodItem], compartments: [Compartment], storage: StorageFilter,
                 kind: ReminderKindFilter, now: Date, fridgeNames: [UUID: String]? = nil) -> [ReminderEntry] {
        allEntries(items: items, compartments: compartments, storage: storage, now: now)
            .map { entry in
                var labelled = entry
                labelled.fridgeName = fridgeNames?[entry.item.fridgeID] ?? (fridgeNames == nil ? nil : "冰箱已刪除")
                return labelled
            }
            .filter { kind.matches($0.kinds) }
            .sorted(by: Self.isMoreUrgent)
    }

    /// Tile counts; identical to `DashboardAggregator` for the same filter.
    func counts(items: [FoodItem], compartments: [Compartment], storage: StorageFilter, now: Date) -> [FoodReminderKind: Int] {
        var counts: [FoodReminderKind: Int] = [.expiringSoon: 0, .expired: 0, .storedTooLong: 0]
        for entry in allEntries(items: items, compartments: compartments, storage: storage, now: now) {
            for kind in entry.kinds { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    private func allEntries(items: [FoodItem], compartments: [Compartment], storage: StorageFilter, now: Date) -> [ReminderEntry] {
        let byID = Dictionary(compartments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let dates = FoodDateCalculator(calendar: evaluator.calendar)
        return items.compactMap { item in
            guard item.isActive else { return nil }
            let compartment = byID[item.compartmentID]
            guard storage.includes(compartment?.storageType) else { return nil }
            let kinds = evaluator.reminders(for: item, now: now)
            guard !kinds.isEmpty else { return nil }
            return ReminderEntry(item: item, compartment: compartment, kinds: kinds,
                                 expiration: evaluator.expirationStatus(of: item, now: now),
                                 daysStored: dates.daysStored(since: item.storedAt, now: now))
        }
    }

    /// Most urgent first: expired (longest ago first), then expiring soon (soonest first), then storage
    /// reminders (most overdue first). Ties break by name then ID so the order is stable.
    static func isMoreUrgent(_ a: ReminderEntry, _ b: ReminderEntry) -> Bool {
        let ka = urgencyKey(a), kb = urgencyKey(b)
        if ka.rank != kb.rank { return ka.rank < kb.rank }
        if ka.value != kb.value { return ka.value < kb.value }
        let byName = a.item.name.localizedStandardCompare(b.item.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.item.id.uuidString < b.item.id.uuidString
    }

    private static func urgencyKey(_ entry: ReminderEntry) -> (rank: Int, value: Int) {
        ReminderUrgency.key(expiration: entry.expiration, daysStored: entry.daysStored,
                            storageReminderDays: entry.item.storageReminderDays)
    }
}

/// Where opening a food (from a reminder or a notification) should lead.
enum FoodRoute: Equatable {
    case editor(UUID)
    /// Consumed, deleted, or not loaded: show a safe explanation.
    case missing

    static func resolve(foodID: UUID, inventory: FoodInventoryService) -> FoodRoute {
        inventory.item(id: foodID) == nil ? .missing : .editor(foodID)
    }
}
