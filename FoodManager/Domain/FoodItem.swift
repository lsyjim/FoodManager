import Foundation

/// One active (or consumed) food record. Its storage classification is never stored here: it is derived
/// from the compartment it sits in (FoodItem → Compartment → StorageType), so moving food re-classifies it.
struct FoodItem: Equatable, Identifiable {
    let id: UUID
    var name: String
    var categoryID: String
    /// Decimal so values like 1.5 公升 are exact.
    var quantity: Decimal
    var unit: String
    var storedAt: Date
    var expirationDate: Date?
    /// Remind once the item has been stored for this many calendar days. Independent of expiry.
    var storageReminderDays: Int?
    var fridgeID: UUID
    var compartmentID: UUID
    var createdAt: Date
    var updatedAt: Date
    /// Set when the user marks the item as eaten/used. Consumed items leave the active inventory.
    var consumedAt: Date?

    var isActive: Bool { consumedAt == nil }
}

/// A stable food category. `id` is persisted on every FoodItem, so never change existing IDs.
struct FoodCategory: Equatable, Identifiable {
    let id: String
    let displayName: String
    /// Name of the illustration in the asset catalog (supplied separately).
    let assetName: String
    /// Single character drawn in the placeholder icon until the illustration exists.
    let placeholderGlyph: String
}

enum FoodCategoryCatalog {
    static let otherID = "other"
    static let frozenPreparedID = "frozen-foods"

    /// The 20 broad categories in their predefined display order (used by the picker after favorites).
    /// IDs are persisted on food records: never rename or remove one. New categories get new IDs.
    ///
    /// `frozen-foods` keeps its original ID but now means frozen *prepared / processed* food (水餃、調理包…).
    /// Whether something is stored frozen comes from its compartment, so the category no longer implies it.
    static let all: [FoodCategory] = [
        FoodCategory(id: "leafy-greens", displayName: "葉菜類", assetName: "category_leafy_greens", placeholderGlyph: "葉"),
        FoodCategory(id: "root-vegetables", displayName: "根莖類", assetName: "category_root_vegetables", placeholderGlyph: "根"),
        FoodCategory(id: "fruiting-vegetables", displayName: "瓜果蔬菜類", assetName: "category_fruiting_vegetables", placeholderGlyph: "瓜"),
        FoodCategory(id: "mushrooms", displayName: "菇菌類", assetName: "category_mushrooms", placeholderGlyph: "菇"),
        FoodCategory(id: "fruits", displayName: "水果類", assetName: "category_fruits", placeholderGlyph: "果"),
        FoodCategory(id: "soy-products", displayName: "豆製品", assetName: "category_soy_products", placeholderGlyph: "豆"),
        FoodCategory(id: "meat", displayName: "肉類", assetName: "category_meat", placeholderGlyph: "肉"),
        FoodCategory(id: "poultry", displayName: "禽肉類", assetName: "category_poultry", placeholderGlyph: "禽"),
        FoodCategory(id: "seafood", displayName: "海鮮類", assetName: "category_seafood", placeholderGlyph: "鮮"),
        FoodCategory(id: "eggs", displayName: "蛋類", assetName: "category_eggs", placeholderGlyph: "蛋"),
        FoodCategory(id: "dairy", displayName: "乳製品", assetName: "category_dairy", placeholderGlyph: "乳"),
        FoodCategory(id: "grains-staples", displayName: "米麵主食", assetName: "category_grains_staples", placeholderGlyph: "米"),
        FoodCategory(id: "bakery", displayName: "麵包烘焙", assetName: "category_bakery", placeholderGlyph: "麵"),
        FoodCategory(id: "prepared-foods", displayName: "熟食類", assetName: "category_prepared_foods", placeholderGlyph: "熟"),
        FoodCategory(id: frozenPreparedID, displayName: "冷凍調理食品", assetName: "category_frozen_foods", placeholderGlyph: "凍"),
        FoodCategory(id: "pickled-canned", displayName: "醃漬罐頭", assetName: "category_pickled_canned", placeholderGlyph: "罐"),
        FoodCategory(id: "snacks-desserts", displayName: "甜點零食", assetName: "category_snacks_desserts", placeholderGlyph: "甜"),
        FoodCategory(id: "beverages", displayName: "飲料類", assetName: "category_beverages", placeholderGlyph: "飲"),
        FoodCategory(id: "condiments", displayName: "調味料", assetName: "category_condiments", placeholderGlyph: "調"),
        FoodCategory(id: otherID, displayName: "其他", assetName: "category_other", placeholderGlyph: "其"),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func contains(_ id: String) -> Bool { byID[id] != nil }

    /// Unknown IDs (e.g. from a future build) fall back to 其他 for display; the stored value is untouched.
    static func category(id: String) -> FoodCategory { byID[id] ?? byID[otherID]! }
}

/// One icon inside a compartment: one per active food record (records sharing a category share artwork
/// but still get their own entry, so the row visualizes how many things are stored).
struct FoodIconEntry: Equatable, Hashable {
    let foodID: UUID
    let categoryID: String
}

/// What a compartment shows: an icon per active food record and the record count (never a quantity sum).
struct CompartmentContentSummary: Equatable {
    var icons: [FoodIconEntry]
    var itemCount: Int { icons.count }

    static let empty = CompartmentContentSummary(icons: [])

    /// Deterministic order: oldest stored first, then name, then ID.
    init(items: [FoodItem]) {
        icons = items
            .sorted { ($0.storedAt, $0.name, $0.id.uuidString) < ($1.storedAt, $1.name, $1.id.uuidString) }
            .map { FoodIconEntry(foodID: $0.id, categoryID: $0.categoryID) }
    }

    init(icons: [FoodIconEntry]) { self.icons = icons }
}

/// Answers how many active food records live in a compartment (used to block deleting occupied compartments).
protocol CompartmentOccupancyProviding {
    func itemCount(in compartmentID: UUID) -> Int
}

struct EmptyOccupancyProvider: CompartmentOccupancyProviding {
    func itemCount(in compartmentID: UUID) -> Int { 0 }
}
