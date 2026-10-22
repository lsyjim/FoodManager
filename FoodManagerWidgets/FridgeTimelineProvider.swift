import SwiftUI
import WidgetKit

/// One timeline entry: the app's latest snapshot, evaluated for `date`.
struct FridgeEntry: TimelineEntry {
    let date: Date
    /// nil when the app hasn't written a (valid) snapshot yet.
    let snapshot: WidgetSnapshot?
    var isSample = false

    var summary: WidgetReminderSummary? { snapshot?.summary(at: date) }
}

/// Reads the snapshot written by the app (read-only) and schedules one entry per calendar day for a week,
/// so "expiring soon / expired / storage" counts roll over at midnight even if the app isn't opened.
/// WidgetKit decides the exact refresh moments; the app also asks for a reload after every change.
struct FridgeTimelineProvider: TimelineProvider {
    static let daysAhead = 7

    func placeholder(in context: Context) -> FridgeEntry {
        FridgeEntry(date: Date(), snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (FridgeEntry) -> Void) {
        let real = WidgetSnapshotFile.shared?.read()
        // The widget gallery shows example content until the app has data; real widgets never do.
        if real == nil && context.isPreview {
            completion(FridgeEntry(date: Date(), snapshot: .sample, isSample: true))
        } else {
            completion(FridgeEntry(date: Date(), snapshot: real))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FridgeEntry>) -> Void) {
        let snapshot = WidgetSnapshotFile.shared?.read()
        let now = Date()
        let calendar = Calendar.current
        var dates = [now]
        var day = calendar.startOfDay(for: now)
        for _ in 0..<Self.daysAhead {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dates.append(next)
            day = next
        }
        let entries = dates.map { FridgeEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(dates.last ?? now)))
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
