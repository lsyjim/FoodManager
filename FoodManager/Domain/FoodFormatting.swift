import Foundation

/// User-facing strings for food quantities and dates. Pure, so they are unit-tested directly.
enum FoodFormatting {
    /// Preset units offered in the editor; users can also type their own.
    static let presetUnits = ["個", "顆", "包", "盒", "瓶", "罐", "袋", "片", "條", "串", "公克", "公斤", "毫升", "公升"]

    static func storageText(daysStored: Int) -> String {
        daysStored <= 0 ? "今天放入" : "已存放 \(daysStored) 天"
    }

    static func expirationText(_ status: ExpirationStatus) -> String? {
        switch status {
        case .none: return nil
        case let .expired(daysAgo): return daysAgo == 0 ? "今天到期" : "已過期 \(daysAgo) 天"
        case let .expiringSoon(daysLeft), let .fresh(daysLeft):
            switch daysLeft {
            case 0: return "今天到期"
            case 1: return "明天到期"
            default: return "\(daysLeft) 天後到期"
            }
        }
    }

    /// "1.5 公升", "6 顆". Up to 2 fraction digits, no grouping, locale-independent decimal point.
    static func quantityText(_ quantity: Decimal, unit: String) -> String {
        "\(number(quantity)) \(unit)"
    }

    static func number(_ value: Decimal) -> String {
        quantityFormatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    /// Parses user input such as "1.5" or "1,5". Returns nil for anything that isn't a plain number.
    static func parseQuantity(_ text: String) -> Decimal? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static let quantityFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
