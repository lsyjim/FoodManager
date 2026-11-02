import Foundation

// Phase 5I: 每週餐桌 and 購物清單. Personal data (local SwiftData, part of manual backups), never shared and never
// synced on its own. Planned ingredients are not food records: planning, completing or shopping never creates,
// changes or deletes inventory by itself.

extension Notification.Name {
    static let mealPlanDidChange = Notification.Name("MealPlanDidChange")
    static let shoppingListDidChange = Notification.Name("ShoppingListDidChange")
}

enum MealType: String, CaseIterable, Codable, Comparable {
    case breakfast
    case lunch
    case dinner

    var title: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        }
    }

    private var order: Int { MealType.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: MealType, b: MealType) -> Bool { a.order < b.order }
}

/// A calendar day as "yyyy-MM-dd" in the user's calendar: a planned dinner stays on the same day when the time zone
/// changes, and keys sort chronologically as strings.
struct DayKey: Hashable, Comparable, Codable {
    let value: String

    init(_ value: String) { self.value = value }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        value = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func date(calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A real calendar day written exactly this way (no rolled-over "2026-13-40").
    var isValid: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard value.count == 10, let date = date(calendar: calendar) else { return false }
        return DayKey(date, calendar: calendar) == self
    }

    static func < (a: DayKey, b: DayKey) -> Bool { a.value < b.value }

    init(from decoder: Decoder) throws { value = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct PlannedIngredient: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var categoryID: String?
    /// Decimal as POSIX text; nil = just "need some" (a checklist item).
    var quantityText: String?
    var unit: String?
    /// The food record the user picked for this ingredient (if it still exists, only it is counted).
    var linkedFoodID: UUID?
    var sortOrder = 0

    var quantity: Decimal? {
        get { quantityText.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
        set { quantityText = newValue.map { ($0 as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX")) } }
    }
}

struct PlannedDish: Codable, Equatable, Identifiable {
    var id = UUID()
    var day: DayKey
    var meal: MealType
    var title: String
    var sortOrder = 0
    var isCompleted = false
    var ingredients: [PlannedIngredient] = []
    var createdAt = Date()
    var updatedAt = Date()

    static let maxTitleLength = 40
    static let maxIngredients = 40

    /// A copy for another day / meal: new IDs everywhere, not completed, edited independently.
    func copied(to day: DayKey, meal: MealType, sortOrder: Int, now: Date = Date()) -> PlannedDish {
        var copy = self
        copy.id = UUID()
        copy.day = day
        copy.meal = meal
        copy.sortOrder = sortOrder
        copy.isCompleted = false
        copy.createdAt = now
        copy.updatedAt = now
        copy.ingredients = ingredients.map { ingredient in
            var new = ingredient
            new.id = UUID()
            return new
        }
        return copy
    }
}

struct ShoppingItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var categoryID: String?
    var quantityText: String?
    var unit: String?
    var isPurchased = false
    var purchasedAt: Date?
    /// Set for items added from 每週餐桌 shortages ("name|unit"), so recalculating never adds the same thing twice.
    var sourceKey: String?
    /// The user changed it after it was added from a shortage: shortage updates never overwrite it.
    var isUserEdited = false
    /// Put into the fridge through the food editor (that food record's ID).
    var storedFoodID: UUID?
    var createdAt = Date()
    var updatedAt = Date()

    static let maxNameLength = 30

    var quantity: Decimal? {
        get { quantityText.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
        set { quantityText = newValue.map { ($0 as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX")) } }
    }

    var quantityLabel: String? {
        guard let quantity else { return unit.flatMap { $0.isEmpty ? nil : $0 } }
        return FoodFormatting.quantityText(quantity, unit: unit ?? "")
    }
}

// MARK: - Week

struct MealWeek {
    var calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // 每週餐桌 always runs Monday → Sunday
        return calendar
    }()

    /// Monday of the week containing `date`.
    func monday(of date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday
        let back = (weekday + 5) % 7 // Monday → 0 … Sunday → 6
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    func days(of date: Date) -> [Date] {
        let start = monday(of: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func week(_ date: Date, offsetBy weeks: Int) -> Date {
        calendar.date(byAdding: .day, value: 7 * weeks, to: monday(of: date)) ?? date
    }
}

// MARK: - Matching

/// Deterministic name and unit rules (no guessing, no AI).
enum IngredientNaming {
    /// Small fixed list of common Traditional Chinese variants; names outside it match only exactly.
    static let synonymGroups: [[String]] = [
        ["雞蛋", "蛋", "雞卵"],
        ["番茄", "蕃茄", "西紅柿"],
        ["馬鈴薯", "洋芋", "土豆"],
        ["高麗菜", "甘藍", "包心菜", "捲心菜"],
        ["牛奶", "鮮奶", "鮮乳", "牛乳"],
        ["青蔥", "蔥"],
        ["豬絞肉", "絞肉"],
        ["蒜頭", "大蒜", "蒜"]
    ]

    private static let canonical: [String: String] = {
        var map: [String: String] = [:]
        for group in synonymGroups { for name in group { map[normalizedRaw(name)] = normalizedRaw(group[0]) } }
        return map
    }()

    private static func normalizedRaw(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping // full-width → half-width
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// The key two names must share to match: trimmed, case- and width-insensitive, synonyms folded.
    static func key(_ name: String) -> String {
        let raw = normalizedRaw(name)
        return canonical[raw] ?? raw
    }

    enum UnitFamily: Equatable {
        case mass
        case volume
        case other(String)
    }

    /// Unit → family and factor to the family's base (g, ml). Only exact, physical conversions; a 包 is never pieces.
    static func unit(_ unit: String?) -> (family: UnitFamily, factor: Decimal)? {
        let raw = normalizedRaw(unit ?? "")
        guard !raw.isEmpty else { return nil }
        switch raw {
        case "g", "克", "公克": return (.mass, 1)
        case "kg", "公斤", "千克": return (.mass, 1000)
        case "ml", "毫升", "cc": return (.volume, 1)
        case "l", "公升", "升": return (.volume, 1000)
        default: return (.other(raw), 1)
        }
    }

    /// `amount` in `from` expressed in `to`, or nil when the units can't be compared reliably.
    static func convert(_ amount: Decimal, from: String?, to: String?) -> Decimal? {
        guard let a = unit(from), let b = unit(to), a.family == b.family else { return nil }
        return amount * a.factor / b.factor
    }
}

enum IngredientAvailabilityStatus: Equatable {
    /// 已備齊
    case ready
    /// 數量不足 (how much is missing, in the ingredient's unit)
    case insufficient(missing: Decimal)
    /// 需要購買 (missing amount when a quantity was given)
    case needToBuy(missing: Decimal?)
    /// 無法確認 (e.g. units that can't be compared)
    case unknown
    /// Completed or past dishes aren't checked.
    case notChecked

    var title: String {
        switch self {
        case .ready: return "已備齊"
        case .insufficient: return "數量不足"
        case .needToBuy: return "需要購買"
        case .unknown: return "無法確認"
        case .notChecked: return "—"
        }
    }

    var needsShopping: Bool {
        switch self {
        case .insufficient, .needToBuy: return true
        default: return false
        }
    }
}

struct IngredientAvailability: Equatable {
    var status: IngredientAvailabilityStatus
    /// Usable (not expired) matching food records.
    var matches: [FoodItem] = []
    var expiredMatches: [FoodItem] = []
    var expiringSoon = false
    /// The linked food record is gone (eaten, deleted or in another fridge).
    var linkedMissing = false
    /// Part or all of it is covered by shopping items marked bought but not put into a fridge yet.
    var coveredByBought = false
    var unit: String?

    /// e.g. "還缺 3 顆", "冰箱裡的已過期".
    var detail: String {
        var parts: [String] = []
        switch status {
        case let .insufficient(missing), let .needToBuy(missing?):
            parts.append("還缺 " + FoodFormatting.quantityText(missing, unit: unit ?? ""))
        case .unknown:
            parts.append("單位不同，無法比較數量")
        default:
            break
        }
        if coveredByBought { parts.append("含已買到、還沒放進冰箱的") }
        if expiringSoon { parts.append("有食材快到期") }
        if !expiredMatches.isEmpty { parts.append("冰箱裡有已過期的，未計入") }
        if linkedMissing { parts.append("原本選的食材已不在冰箱") }
        return parts.joined(separator: "，")
    }
}

/// One line of the shopping preview: what the uncompleted plan still needs.
struct MealShortage: Equatable {
    let key: String
    let name: String
    let categoryID: String?
    var quantity: Decimal?
    let unit: String?
    var dishTitles: [String]
}

/// Compares planned ingredients with the active food of the fridges in scope.
///
/// Allocation (shown in the UI): uncompleted dishes from today on are served in date → meal → dish order, and each
/// takes from the matching food records (soonest-expiring first) before the next one. So two meals that need the same
/// eggs can never both be "已備齊" from the same carton. Expired food is never counted as usable; past and completed
/// dishes aren't checked. A linked food record, when it still exists, is the only supply of that ingredient.
/// Shopping items marked bought but not yet put into a fridge (`bought`) are used after the fridge, matched by name:
/// they're already bought, so they're never offered for shopping again. One without a quantity, or in a unit that
/// can't be compared, covers the ingredient.
struct MealPlanAnalyzer {
    var calendar: Calendar = .current
    var evaluator = FoodReminderEvaluator()

    func analyze(dishes: [PlannedDish], inventory: [FoodItem], bought: [ShoppingItem] = [],
                 now: Date) -> [UUID: IngredientAvailability] {
        let today = DayKey(now, calendar: calendar)
        let active = inventory.filter(\.isActive)
        let bought = bought.filter { $0.isPurchased && $0.storedFoodID == nil }
        var remaining = Dictionary(active.map { ($0.id, $0.quantity) }, uniquingKeysWith: { first, _ in first })
        for item in bought { remaining[item.id] = item.quantity }
        var result: [UUID: IngredientAvailability] = [:]

        let ordered = dishes.sorted { ($0.day, $0.meal, $0.sortOrder, $0.id.uuidString) < ($1.day, $1.meal, $1.sortOrder, $1.id.uuidString) }
        for dish in ordered {
            let checked = !dish.isCompleted && dish.day >= today
            for ingredient in dish.ingredients.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard checked else {
                    result[ingredient.id] = IngredientAvailability(status: .notChecked, unit: ingredient.unit)
                    continue
                }
                result[ingredient.id] = availability(of: ingredient, active: active, bought: bought, remaining: &remaining, now: now)
            }
        }
        return result
    }

    private func availability(of ingredient: PlannedIngredient, active: [FoodItem], bought: [ShoppingItem],
                              remaining: inout [UUID: Decimal], now: Date) -> IngredientAvailability {
        var linkedMissing = false
        var candidates: [FoodItem]
        if let linked = ingredient.linkedFoodID, let food = active.first(where: { $0.id == linked }) {
            candidates = [food]
        } else {
            linkedMissing = ingredient.linkedFoodID != nil
            let key = IngredientNaming.key(ingredient.name)
            candidates = active.filter { IngredientNaming.key($0.name) == key }
        }
        let isExpired: (FoodItem) -> Bool = {
            if case .expired = evaluator.expirationStatus(of: $0, now: now) { return true }
            return false
        }
        let usable = candidates.filter { !isExpired($0) }
            .sorted { ($0.expirationDate ?? .distantFuture, $0.storedAt, $0.id.uuidString) < ($1.expirationDate ?? .distantFuture, $1.storedAt, $1.id.uuidString) }
        var info = IngredientAvailability(status: .unknown, matches: usable, expiredMatches: candidates.filter(isExpired),
                                          expiringSoon: usable.contains {
                                              if case .expiringSoon = evaluator.expirationStatus(of: $0, now: now) { return true }
                                              return false
                                          },
                                          linkedMissing: linkedMissing, unit: ingredient.unit)

        let boughtMatches = bought.filter { IngredientNaming.key($0.name) == IngredientNaming.key(ingredient.name) }

        guard let needed = ingredient.quantity, needed > 0 else {
            // Checklist ingredient: only "is there any".
            if usable.isEmpty, !boughtMatches.isEmpty { info.coveredByBought = true }
            info.status = usable.isEmpty && boughtMatches.isEmpty ? .needToBuy(missing: nil) : .ready
            return info
        }
        let compatible = usable.filter { IngredientNaming.convert(1, from: $0.unit, to: ingredient.unit) != nil }
        var need = needed
        for food in compatible where need > 0 {
            let left = remaining[food.id] ?? 0
            guard left > 0, let available = IngredientNaming.convert(left, from: food.unit, to: ingredient.unit) else { continue }
            let take = min(available, need)
            need -= take
            remaining[food.id] = left - (IngredientNaming.convert(take, from: ingredient.unit, to: food.unit) ?? left)
        }
        for item in boughtMatches where need > 0 {
            guard let left = remaining[item.id], IngredientNaming.convert(1, from: item.unit, to: ingredient.unit) != nil else {
                // No quantity, or a unit that can't be compared: it was bought for this, so it covers it.
                info.coveredByBought = true
                need = 0
                break
            }
            guard left > 0, let available = IngredientNaming.convert(left, from: item.unit, to: ingredient.unit) else { continue }
            let take = min(available, need)
            need -= take
            info.coveredByBought = true
            remaining[item.id] = left - (IngredientNaming.convert(take, from: ingredient.unit, to: item.unit) ?? left)
        }
        if need <= 0 {
            info.status = .ready
        } else if usable.isEmpty {
            info.status = need == needed ? .needToBuy(missing: need) : .insufficient(missing: need)
        } else if compatible.isEmpty {
            info.status = .unknown // e.g. 2 盒 in the fridge, 300 g planned
        } else {
            info.status = .insufficient(missing: need)
        }
        return info
    }

    /// What to buy for the uncompleted plan, combined per ingredient name and unit.
    func shortages(dishes: [PlannedDish], inventory: [FoodItem], bought: [ShoppingItem] = [], now: Date) -> [MealShortage] {
        let availability = analyze(dishes: dishes, inventory: inventory, bought: bought, now: now)
        var lines: [String: MealShortage] = [:]
        var order: [String] = []
        let ordered = dishes.sorted { ($0.day, $0.meal, $0.sortOrder) < ($1.day, $1.meal, $1.sortOrder) }
        for dish in ordered {
            for ingredient in dish.ingredients.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard let info = availability[ingredient.id], info.status.needsShopping else { continue }
                let missing: Decimal?
                switch info.status {
                case let .insufficient(amount): missing = amount
                case let .needToBuy(amount): missing = amount
                default: missing = nil
                }
                let key = Self.shortageKey(name: ingredient.name, unit: missing == nil ? nil : ingredient.unit)
                if var line = lines[key] {
                    if let missing { line.quantity = (line.quantity ?? 0) + missing }
                    if !line.dishTitles.contains(dish.title) { line.dishTitles.append(dish.title) }
                    lines[key] = line
                } else {
                    order.append(key)
                    lines[key] = MealShortage(key: key, name: ingredient.name, categoryID: ingredient.categoryID, quantity: missing,
                                              unit: missing == nil ? nil : ingredient.unit, dishTitles: [dish.title])
                }
            }
        }
        return order.compactMap { lines[$0] }
    }

    static func shortageKey(name: String, unit: String?) -> String {
        IngredientNaming.key(name) + "|" + (unit.map { IngredientNaming.key($0) } ?? "")
    }
}

/// How adding shortages to the shopping list treats what is already there: never a duplicate, never an overwrite of
/// something the user changed.
enum ShoppingMerge {
    enum Action: Equatable {
        case add
        /// A pending item generated earlier (not edited by the user) gets the new amount.
        case update(itemID: UUID)
        /// Already on the list (covered, or edited by the user): nothing to do.
        case alreadyListed(edited: Bool)
    }

    static func action(for shortage: MealShortage, pending: [ShoppingItem]) -> Action {
        guard let existing = pending.first(where: { !$0.isPurchased && $0.sourceKey == shortage.key })
            ?? pending.first(where: { !$0.isPurchased && $0.sourceKey == nil
                && MealPlanAnalyzer.shortageKey(name: $0.name, unit: shortage.unit == nil ? nil : $0.unit) == shortage.key }) else {
            return .add
        }
        if existing.isUserEdited || existing.sourceKey == nil { return .alreadyListed(edited: true) }
        if let needed = shortage.quantity, (existing.quantity ?? 0) < needed { return .update(itemID: existing.id) }
        return .alreadyListed(edited: false)
    }
}

/// The quick-add line of 購物清單: "牛奶 2 瓶", "雞蛋3", "可樂 1.5 L" or just "豆腐".
enum ShoppingQuickEntry {
    static func parse(_ text: String) -> (name: String, quantity: Decimal?, unit: String?)? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if let match = line.wholeMatch(of: /(.+?)\s*(\d+(?:\.\d+)?)\s*([^\d\s]{0,8})/),
           let quantity = FoodFormatting.parseQuantity(String(match.2)), quantity > 0 {
            let name = String(match.1).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let unit = String(match.3)
                return (name, quantity, unit.isEmpty ? nil : unit)
            }
        }
        return (line, nil, nil)
    }
}
