import SwiftUI
import WidgetKit

@main
struct FoodManagerWidgetBundle: WidgetBundle {
    var body: some Widget {
        FridgeSummaryWidget()
        QuickAddWidget()
    }
}

// MARK: - Fridge summary (small / medium / large / lock screen)

struct FridgeSummaryWidget: Widget {
    static let kind = "FridgeSummaryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FridgeTimelineProvider()) { entry in
            FridgeSummaryView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.background }
        }
        .configurationDisplayName("我的冰箱")
        .description("即將到期、已過期與保存提醒，冷藏與冷凍分開顯示。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}

struct FridgeSummaryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FridgeEntry

    var body: some View {
        if let snapshot = entry.snapshot, let summary = entry.summary {
            switch family {
            case .systemSmall: SmallFridgeView(name: snapshot.refrigeratorName, summary: summary)
            case .systemMedium: MediumFridgeView(name: snapshot.refrigeratorName, summary: summary)
            case .systemLarge: LargeFridgeView(name: snapshot.refrigeratorName, summary: summary)
            case .accessoryCircular: CircularAttentionView(count: summary.attentionCount)
            case .accessoryRectangular: RectangularAttentionView(summary: summary)
            default: SmallFridgeView(name: snapshot.refrigeratorName, summary: summary)
            }
        } else {
            switch family {
            case .accessoryCircular, .accessoryRectangular:
                Image(systemName: "refrigerator").font(.title2).widgetURL(AppDeepLink(.home).url)
            default:
                OpenAppPrompt(compact: family == .systemSmall)
            }
        }
    }
}

/// Small: one destination only (small widgets have a single tap target), so it opens the reminder center.
/// Quick add lives in the separate 快速新增 widget instead of a fake button.
struct SmallFridgeView: View {
    let name: String
    let summary: WidgetReminderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image("fridge_closed").resizable().scaledToFit().frame(height: 30).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Text("\(summary.attentionCount)")
                .font(.system(size: 44, weight: .light))
                .monospacedDigit()
                .foregroundStyle(summary.expiredCount > 0 ? WidgetPalette.alert : WidgetPalette.textPrimary)
                .contentTransition(.numericText())
            Text(summary.attentionCount == 0 ? "沒有需要注意的食材" : "項食材需要注意")
                .font(.system(size: 12))
                .foregroundStyle(WidgetPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                storageLabel("冷藏", count: summary.refrigeratedCount, type: .refrigerated)
                storageLabel("冷凍", count: summary.frozenCount, type: .frozen)
            }
        }
        .widgetURL(AppDeepLink(.reminders(storage: .all, kind: .all)).url)
        .accessibilityElement(children: .combine)
    }

    private func storageLabel(_ title: String, count: Int, type: StorageType) -> some View {
        HStack(spacing: 4) {
            StorageDot(color: WidgetPalette.storage(type))
            Text("\(title) \(count)").font(.system(size: 11)).foregroundStyle(WidgetPalette.textSecondary).monospacedDigit()
        }
    }
}

struct MediumFridgeView: View {
    let name: String
    let summary: WidgetReminderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FridgeHeader(name: name, summary: summary)
            HStack(spacing: 8) {
                StorageCountCard(title: "冷藏", storage: .refrigerated, count: summary.refrigeratedCount, filter: .refrigerated)
                StorageCountCard(title: "冷凍", storage: .frozen, count: summary.frozenCount, filter: .frozen)
            }
            HStack(spacing: 6) {
                if let top = summary.entries.first {
                    Link(destination: AppDeepLink(.food(top.item.id)).url) {
                        Text("\(top.item.name) · \(top.primaryStatus)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(top.kinds.contains(.expired) ? WidgetPalette.alert : WidgetPalette.textPrimary)
                            .lineLimit(1)
                    }
                } else {
                    Text("冰箱裡的食材都還好").font(.system(size: 12)).foregroundStyle(WidgetPalette.textSecondary)
                }
                Spacer(minLength: 4)
                Link(destination: AppDeepLink(.reminders(storage: .all, kind: .all)).url) {
                    Text("查看提醒 \(Image(systemName: "arrow.up.right"))")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetPalette.textSecondary)
                }
            }
        }
    }
}

struct LargeFridgeView: View {
    static let maxRows = 5

    let name: String
    let summary: WidgetReminderSummary

    private struct Section {
        let title: String
        let filter: ReminderKindFilter
        let entries: [WidgetReminderSummary.Entry]
    }

    /// Up to `maxRows` foods in urgency order, each listed once under its most important status.
    private var sections: [Section] {
        let shown = summary.entries.prefix(Self.maxRows)
        func primary(_ entry: WidgetReminderSummary.Entry) -> FoodReminderKind {
            entry.kinds.contains(.expired) ? .expired : entry.kinds.contains(.expiringSoon) ? .expiringSoon : .storedTooLong
        }
        let groups: [(String, ReminderKindFilter, FoodReminderKind)] = [
            ("已過期", .expired, .expired), ("即將到期", .expiringSoon, .expiringSoon), ("保存提醒", .storedTooLong, .storedTooLong),
        ]
        return groups.compactMap { title, filter, kind in
            let entries = shown.filter { primary($0) == kind }
            return entries.isEmpty ? nil : Section(title: title, filter: filter, entries: Array(entries))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FridgeHeader(name: name, summary: summary)
            HStack(spacing: 8) {
                StorageCountCard(title: "冷藏", storage: .refrigerated, count: summary.refrigeratedCount, filter: .refrigerated)
                StorageCountCard(title: "冷凍", storage: .frozen, count: summary.frozenCount, filter: .frozen)
            }
            if summary.entries.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light))
                        Text("目前沒有需要注意的食材").font(.system(size: 13))
                    }
                    .foregroundStyle(WidgetPalette.textSecondary)
                    Spacer()
                }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sections, id: \.title) { section in
                        Link(destination: AppDeepLink(.reminders(storage: .all, kind: section.filter)).url) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WidgetPalette.textSecondary)
                        }
                        ForEach(section.entries) { UrgentFoodRow(entry: $0) }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WidgetPalette.card))
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Link(destination: AppDeepLink(.reminders(storage: .all, kind: .all)).url) {
                    Text("查看全部 \(summary.attentionCount) 項 \(Image(systemName: "arrow.up.right"))")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetPalette.textSecondary)
                }
            }
        }
    }
}

// MARK: - Lock screen

/// Monochrome-friendly: no illustrations, just the attention count.
struct CircularAttentionView: View {
    let count: Int

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if count == 0 {
                Image(systemName: "refrigerator").font(.system(size: 20, weight: .medium))
            } else {
                VStack(spacing: -2) {
                    Text("\(count)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("注意").font(.system(size: 9, weight: .medium))
                }
            }
        }
        .widgetAccentable()
        .widgetURL(AppDeepLink(.reminders(storage: .all, kind: .all)).url)
        .accessibilityLabel(count == 0 ? "冰箱沒有需要注意的食材" : "冰箱有 \(count) 項食材需要注意")
    }
}

struct RectangularAttentionView: View {
    let summary: WidgetReminderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("冰箱提醒", systemImage: "refrigerator")
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
            Text(summary.attentionCount == 0 ? "沒有需要注意的食材" : "\(summary.attentionCount) 項需要注意")
                .font(.system(size: 13))
            if let top = summary.entries.first {
                Text("\(top.item.name) · \(top.primaryStatus)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("冷藏 \(summary.refrigeratedCount) · 冷凍 \(summary.frozenCount)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(AppDeepLink(.reminders(storage: .all, kind: .all)).url)
    }
}

// MARK: - Quick add

struct QuickAddWidget: Widget {
    static let kind = "QuickAddWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickAddProvider()) { _ in
            QuickAddView()
                .containerBackground(for: .widget) { WidgetPalette.background }
        }
        .configurationDisplayName("快速新增")
        .description("一鍵打開新增食材，自動帶入上次使用的隔層。")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickAddProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: Date())], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry { let date: Date }

struct QuickAddView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                }
                .widgetAccentable()
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("快速新增").font(.system(size: 13, weight: .semibold)).foregroundStyle(WidgetPalette.textPrimary)
                        Spacer()
                        Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(WidgetPalette.stroke)
                    }
                    Spacer(minLength: 4)
                    Image("fridge_closed").resizable().scaledToFit().frame(height: 58).accessibilityHidden(true)
                    Text("加入食材")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(WidgetPalette.textPrimary)
                        .padding(.top, 6)
                    Spacer(minLength: 4)
                    Text("開啟新增表單").font(.system(size: 11)).foregroundStyle(WidgetPalette.textSecondary)
                }
            }
        }
        .widgetURL(AppDeepLink(.quickAdd(compartmentID: nil)).url)
        .accessibilityLabel("新增食材")
    }
}

// MARK: - Previews (gallery-style sample data, never used at runtime)

#Preview("Small", as: .systemSmall) { FridgeSummaryWidget() } timeline: { FridgeEntry(date: .now, snapshot: .sample) }
#Preview("Medium", as: .systemMedium) { FridgeSummaryWidget() } timeline: { FridgeEntry(date: .now, snapshot: .sample) }
#Preview("Large", as: .systemLarge) { FridgeSummaryWidget() } timeline: { FridgeEntry(date: .now, snapshot: .sample) }
#Preview("Quick add", as: .systemSmall) { QuickAddWidget() } timeline: { SimpleEntry(date: .now) }
