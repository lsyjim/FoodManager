import Foundation

enum FavoriteCategoryError: Error, Equatable {
    case limitReached
    case unknownCategory

    var message: String {
        switch self {
        case .limitReached: return "常用分類最多 \(FavoriteCategories.maxCount) 個，請先取消釘選其他分類"
        case .unknownCategory: return "找不到這個分類"
        }
    }
}

/// The user's pinned categories: at most 5, kept in the order the user pinned them (never usage-based).
struct FavoriteCategories: Equatable {
    static let maxCount = 5

    private(set) var ids: [String]

    /// Drops unknown or duplicate IDs (e.g. from an older/newer build) and anything past the limit.
    init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { FoodCategoryCatalog.contains($0) && seen.insert($0).inserted }.prefix(Self.maxCount))
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Appends to the end of the favorites. Pinning an already pinned category is a no-op.
    mutating func pin(_ id: String) throws {
        guard FoodCategoryCatalog.contains(id) else { throw FavoriteCategoryError.unknownCategory }
        guard !ids.contains(id) else { return }
        guard ids.count < Self.maxCount else { throw FavoriteCategoryError.limitReached }
        ids.append(id)
    }

    mutating func unpin(_ id: String) {
        ids.removeAll { $0 == id }
    }
}

/// What the category picker shows: favorites first (in pin order), then every other category in
/// catalog order. A category never appears in both sections.
struct CategoryPickerSections: Equatable {
    let favorites: [FoodCategory]
    let others: [FoodCategory]

    init(favorites: FavoriteCategories, query: String = "") {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (FoodCategory) -> Bool = { trimmed.isEmpty || $0.displayName.localizedStandardContains(trimmed) }
        self.favorites = favorites.ids.map(FoodCategoryCatalog.category(id:)).filter(matches)
        others = FoodCategoryCatalog.all.filter { !favorites.contains($0.id) && matches($0) }
    }

    var isEmpty: Bool { favorites.isEmpty && others.isEmpty }
}

/// Local persistence for favorites (device-only preference, not part of the food data).
protocol FavoriteCategoryStore: AnyObject {
    func load() -> FavoriteCategories
    func save(_ favorites: FavoriteCategories)
}

final class UserDefaultsFavoriteCategoryStore: FavoriteCategoryStore {
    static let key = "favoriteCategoryIDs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FavoriteCategories {
        FavoriteCategories(ids: defaults.stringArray(forKey: Self.key) ?? [])
    }

    func save(_ favorites: FavoriteCategories) {
        defaults.set(favorites.ids, forKey: Self.key)
        PreferenceCloudSync.noteLocalChange(key: Self.key, defaults: defaults)
    }
}
