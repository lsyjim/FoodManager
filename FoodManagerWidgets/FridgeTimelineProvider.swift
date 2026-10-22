import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Fridge selection (widget configuration)

/// A fridge as offered in the widget's 選擇冰箱 setting. Read from the app's snapshot file only.
struct FridgeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "冰箱"
    static var defaultQuery = FridgeEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct FridgeEntityQuery: EntityQuery {
    private var all: [FridgeEntity] {
        (WidgetSnapshotFile.shared?.read()?.fridges ?? []).map { FridgeEntity(id: $0.refrigeratorID.uuidString, name: $0.refrigeratorName) }
    }

    func entities(for identifiers: [FridgeEntity.ID]) async throws -> [FridgeEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FridgeEntity] { all }
}

/// Which fridge a widget shows. Empty (default) = follow the fridge currently selected in the app.
struct SelectFridgeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "選擇冰箱"
    static var description = IntentDescription("選擇要顯示的冰箱；不選則跟隨 App 目前使用的冰箱。")

    @Parameter(title: "冰箱")
    var fridge: FridgeEntity?

    init() {}
}

// MARK: - Timeline

/// One timeline entry: the configured fridge's latest snapshot, evaluated for `date`.
struct FridgeEntry: TimelineEntry {
    let date: Date
    /// nil when the app hasn't written a (valid) snapshot yet.
    let snapshot: WidgetSnapshot?
    /// The fridge's ID to put in links — only when the user picked a fridge (otherwise links follow the app).
    var linkFridgeID: UUID?
    var isSample = false

    var summary: WidgetReminderSummary? { snapshot?.summary(at: date) }
}

/// Reads the snapshot written by the app (read-only) and schedules one entry per calendar day for a week,
/// so "expiring soon / expired / storage" counts roll over at midnight even if the app isn't opened.
/// WidgetKit decides the exact refresh moments; the app also asks for a reload after every change.
struct FridgeTimelineProvider: AppIntentTimelineProvider {
    static let daysAhead = 7

    func placeholder(in context: Context) -> FridgeEntry {
        FridgeEntry(date: Date(), snapshot: .sample, isSample: true)
    }

    func snapshot(for configuration: SelectFridgeIntent, in context: Context) async -> FridgeEntry {
        let entry = makeEntry(configuration, date: Date())
        // The widget gallery shows example content until the app has data; real widgets never do.
        if entry.snapshot == nil && context.isPreview { return FridgeEntry(date: Date(), snapshot: .sample, isSample: true) }
        return entry
    }

    func timeline(for configuration: SelectFridgeIntent, in context: Context) async -> Timeline<FridgeEntry> {
        let now = Date()
        let calendar = Calendar.current
        var dates = [now]
        var day = calendar.startOfDay(for: now)
        for _ in 0..<Self.daysAhead {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dates.append(next)
            day = next
        }
        let entries = dates.map { makeEntry(configuration, date: $0) }
        return Timeline(entries: entries, policy: .after(dates.last ?? now))
    }

    /// A configured fridge that no longer exists falls back to the app's current fridge (never stale food).
    private func makeEntry(_ configuration: SelectFridgeIntent, date: Date) -> FridgeEntry {
        let bundle = WidgetSnapshotFile.shared?.read()
        let requested = configuration.fridge.flatMap { UUID(uuidString: $0.id) }
        let snapshot = bundle?.snapshot(for: requested)
        let pinned = requested.flatMap { id in snapshot?.refrigeratorID == id ? id : nil }
        return FridgeEntry(date: date, snapshot: snapshot, linkFridgeID: pinned)
    }
}

// MARK: - Links

private struct LinkFridgeIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// Fridge to put in deep links (nil = the app's current fridge).
    var linkFridgeID: UUID? {
        get { self[LinkFridgeIDKey.self] }
        set { self[LinkFridgeIDKey.self] = newValue }
    }
}

extension WidgetSnapshot {
    /// Example content for the widget gallery only.
    static var sample: WidgetSnapshot {
        let now = Date()
        func day(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: now)! }
        let items = [
            Item(id: UUID(), name: "牛奶", categoryAssetName: "category_dairy", locationName: "櫃內 · 上層", storage: .refrigerated,
                 storedAt: day(-3), expirationDate: day(1), storageReminderDays: nil),
            Item(id: UUID(), name: "菠菜", categoryAssetName: "category_leafy_greens", locationName: "櫃內 · 蔬果抽屜", storage: .refrigerated,
                 storedAt: day(-6), expirationDate: day(-1), storageReminderDays: nil),
            Item(id: UUID(), name: "冷凍水餃", categoryAssetName: "category_frozen_foods", locationName: "櫃內 · 冷凍抽屜", storage: .frozen,
                 storedAt: day(-30), expirationDate: nil, storageReminderDays: 21),
        ]
        return WidgetSnapshot(snapshotVersion: currentVersion, generatedAt: now, refrigeratorID: UUID(), refrigeratorName: "我的冰箱",
                              activeFoodCount: 12, refrigeratedReminderCount: 2, frozenReminderCount: 1, unspecifiedReminderCount: 0,
                              expiredCount: 1, expiringSoonCount: 1, storageReminderCount: 1, urgentFoodItems: items, isTruncated: false)
    }
}
