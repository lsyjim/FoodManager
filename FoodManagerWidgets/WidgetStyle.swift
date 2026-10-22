import SwiftUI

/// The app's warm-gray palette, for the home-screen widgets.
enum WidgetPalette {
    static let background = Color(hex: 0xF3F1ED)
    static let card = Color(hex: 0xFAF9F6)
    static let body = Color(hex: 0xE7E5E0)
    static let textPrimary = Color(hex: 0x383733)
    static let textSecondary = Color(hex: 0x827F79)
    static let stroke = Color(hex: 0x55514B)
    static let divider = Color(hex: 0xB6B2AA)
    static let refrigerated = Color(hex: 0xB6B2AA)
    static let frozen = Color(hex: 0x8FB8C3)
    static let alert = Color(hex: 0xA0473A)

    static func storage(_ type: StorageType?) -> Color {
        switch type {
        case .frozen: return frozen
        case .refrigerated: return refrigerated
        default: return divider
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Small filled dot marking 冷藏 / 冷凍, matching the dots inside the app's compartments.
struct StorageDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

/// Round "+" used as the quick-add link in medium/large widgets.
struct AddBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(WidgetPalette.stroke)
            .frame(width: 34, height: 34)
            .background(Circle().fill(WidgetPalette.body))
            .accessibilityLabel("新增食材")
    }
}

/// Header shared by medium and large widgets: fridge illustration, name, today's total, quick add.
struct FridgeHeader: View {
    @Environment(\.linkFridgeID) private var linkFridgeID
    let name: String
    let summary: WidgetReminderSummary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("fridge_closed")
                .resizable()
                .scaledToFit()
                .frame(height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Link(destination: AppDeepLink(.quickAdd(compartmentID: nil), refrigeratorID: linkFridgeID).url) { AddBadge() }
        }
    }

    private var subtitle: String {
        guard summary.attentionCount > 0 else { return "目前沒有需要注意的食材" }
        let door = summary.unspecifiedCount > 0 ? "（含門內 \(summary.unspecifiedCount) 項）" : ""
        return "今天需要注意 \(summary.attentionCount) 項\(door)"
    }
}

/// 冷藏 / 冷凍 count card; taps open the reminder center filtered to that storage type.
struct StorageCountCard: View {
    @Environment(\.linkFridgeID) private var linkFridgeID
    let title: String
    let storage: StorageType
    let count: Int
    let filter: StorageFilter

    var body: some View {
        Link(destination: AppDeepLink(.reminders(storage: filter, kind: .all), refrigeratorID: linkFridgeID).url) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    StorageDot(color: WidgetPalette.storage(storage))
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(WidgetPalette.textSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(count)")
                        .font(.system(size: 26, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.textPrimary)
                        .contentTransition(.numericText())
                    Text("項提醒").font(.system(size: 11)).foregroundStyle(WidgetPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WidgetPalette.card))
        }
        .accessibilityLabel("\(title) \(count) 項提醒")
    }
}

/// One urgent food: illustration, name, location and its most important status.
struct UrgentFoodRow: View {
    @Environment(\.linkFridgeID) private var linkFridgeID
    let entry: WidgetReminderSummary.Entry
    var showsLocation = true

    var body: some View {
        Link(destination: AppDeepLink(.food(entry.item.id), refrigeratorID: linkFridgeID).url) {
            HStack(spacing: 10) {
                Image(entry.item.categoryAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WidgetPalette.textPrimary)
                        .lineLimit(1)
                    if showsLocation {
                        Text(entry.item.locationName ?? "位置不存在")
                            .font(.system(size: 11))
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(entry.primaryStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(entry.kinds.contains(.expired) ? WidgetPalette.alert : WidgetPalette.textPrimary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("\(entry.item.name)，\(entry.primaryStatus)")
    }
}

/// Shown until the app has written a snapshot (or if it is unreadable).
struct OpenAppPrompt: View {
    @Environment(\.linkFridgeID) private var linkFridgeID
    var compact = false

    var body: some View {
        VStack(spacing: 8) {
            Image("fridge_closed").resizable().scaledToFit().frame(height: compact ? 34 : 44)
            Text("開啟冰箱管理員\n以同步食材")
                .font(.system(size: compact ? 11 : 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(WidgetPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(AppDeepLink(.home, refrigeratorID: linkFridgeID).url)
    }
}
