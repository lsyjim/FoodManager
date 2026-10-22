import Foundation

/// Name comparison used for de-duplication: trims, ignores case and full/half width ("Ｍｉｌｋ" == "milk").
enum FoodNameKey {
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// What fast entry fills in. Never carries quantity, expiration or reminder settings.
struct FoodTemplate: Equatable {
    var name: String
    var categoryID: String
    var unit: String
    /// Only favorites may carry one; it is applied only if the compartment still exists.
    var preferredCompartmentID: UUID?
}

extension FoodDraft {
    /// Fills name, category and unit. A favorite's preferred compartment is used only when it still exists
    /// and no destination was chosen yet (opening from a compartment keeps that compartment).
    /// Quantity, storedAt, expiration and storage reminder are deliberately left as they are.
    mutating func apply(_ template: FoodTemplate, validCompartmentIDs: Set<UUID>) {
        name = template.name
        categoryID = FoodCategoryCatalog.contains(template.categoryID) ? template.categoryID : FoodCategoryCatalog.otherID
        unit = template.unit
        let currentIsValid = compartmentID.map(validCompartmentIDs.contains) ?? false
        if !currentIsValid, let preferred = template.preferredCompartmentID, validCompartmentIDs.contains(preferred) {
            compartmentID = preferred
        }
    }

    /// State after "儲存並繼續新增": keeps fridge, a still-valid compartment and the storedAt date;
    /// resets everything describing the specific item.
    func nextEntry(validCompartmentIDs: Set<UUID>) -> FoodDraft {
        var next = FoodDraft(compartmentID: compartmentID.flatMap { validCompartmentIDs.contains($0) ? $0 : nil },
                             now: storedAt)
        next.storedAt = storedAt
        return next
    }
}

// MARK: - Recent foods

enum RecentFoodSuggestions {
    static let defaultLimit = 12

    /// Most recently used distinct foods (by normalized name) from active and consumed records.
    /// Uses each name's latest record for category and unit. No predefined food database.
    static func build(from records: [FoodItem], limit: Int = defaultLimit) -> [FoodTemplate] {
        func lastUsed(_ item: FoodItem) -> Date { max(item.updatedAt, item.consumedAt ?? .distantPast, item.createdAt) }
        var seen = Set<String>()
        var result: [FoodTemplate] = []
        for item in records.sorted(by: { (lastUsed($0), $0.id.uuidString) > (lastUsed($1), $1.id.uuidString) }) {
            let key = FoodNameKey.normalize(item.name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(FoodTemplate(name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       categoryID: item.categoryID, unit: item.unit))
            if result.count == limit { break }
        }
        return result
    }

    /// Filters suggestions by what the user is typing.
    static func filter(_ suggestions: [FoodTemplate], query: String) -> [FoodTemplate] {
        let key = FoodNameKey.normalize(query)
        return key.isEmpty ? suggestions : suggestions.filter { FoodNameKey.normalize($0.name).contains(key) }
    }
}

// MARK: - Favorite foods

/// A manually pinned food template with a stable ID. Contains no dates or quantities.
struct FavoriteFoodTemplate: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var categoryID: String
    var unit: String
    var preferredCompartmentID: UUID?

    var template: FoodTemplate {
        FoodTemplate(name: name, categoryID: categoryID, unit: unit, preferredCompartmentID: preferredCompartmentID)
    }
}

enum FavoriteFoodError: Error, Equatable {
    case duplicate
    case limitReached
    case invalidName

    var message: String {
        switch self {
        case .duplicate: return "這個食材已在常用食材中"
        case .limitReached: return "常用食材最多 \(FavoriteFoods.maxCount) 個，請先取消釘選其他食材"
        case .invalidName: return "請先輸入食材名稱"
        }
    }
}

/// Pinned favorite foods in the user's own order (never re-sorted by usage).
struct FavoriteFoods: Equatable {
    static let maxCount = 20
    private(set) var templates: [FavoriteFoodTemplate]

    /// Drops duplicate names and anything past the limit (e.g. corrupt stored data).
    init(templates: [FavoriteFoodTemplate] = []) {
        var seen = Set<String>()
        self.templates = Array(templates.filter {
            let key = FoodNameKey.normalize($0.name)
            return !key.isEmpty && seen.insert(key).inserted
        }.prefix(Self.maxCount))
    }

    func contains(name: String) -> Bool {
        let key = FoodNameKey.normalize(name)
        return templates.contains { FoodNameKey.normalize($0.name) == key }
    }

    @discardableResult
    mutating func pin(_ template: FoodTemplate, id: UUID = UUID()) throws -> FavoriteFoodTemplate {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FavoriteFoodError.invalidName }
        guard !contains(name: name) else { throw FavoriteFoodError.duplicate }
        guard templates.count < Self.maxCount else { throw FavoriteFoodError.limitReached }
        let favorite = FavoriteFoodTemplate(id: id, name: name, categoryID: template.categoryID, unit: template.unit,
                                            preferredCompartmentID: template.preferredCompartmentID)
        templates.append(favorite)
        return favorite
    }

    mutating func unpin(_ id: UUID) {
        templates.removeAll { $0.id == id }
    }

    /// Manual reordering (the only way the order ever changes besides pin/unpin).
    mutating func move(from source: Int, to destination: Int) {
        guard templates.indices.contains(source), templates.indices.contains(destination) else { return }
        templates.insert(templates.remove(at: source), at: destination)
    }
}

protocol FavoriteFoodStore: AnyObject {
    func load() -> FavoriteFoods
    func save(_ favorites: FavoriteFoods)
}

/// Device-local storage (a preference, not inventory data — no SwiftData schema change).
final class UserDefaultsFavoriteFoodStore: FavoriteFoodStore {
    static let key = "favoriteFoodTemplates"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> FavoriteFoods {
        guard let data = defaults.data(forKey: Self.key),
              let templates = try? JSONDecoder().decode([FavoriteFoodTemplate].self, from: data) else { return FavoriteFoods() }
        return FavoriteFoods(templates: templates)
    }

    func save(_ favorites: FavoriteFoods) {
        defaults.set(try? JSONEncoder().encode(favorites.templates), forKey: Self.key)
        PreferenceCloudSync.noteLocalChange(key: Self.key, defaults: defaults)
    }
}

// MARK: - History statistics

/// Lightweight statistics from real consumed records only (never estimated from quantities).
struct HistoryStatistics: Equatable {
    struct NameCount: Equatable {
        let name: String
        let count: Int
    }

    let consumedCount: Int
    let topNames: [NameCount]
    /// Average calendar days between storedAt and consumedAt; nil when no record has a valid consumedAt.
    let averageStorageDays: Double?

    init(history: [FoodItem], calendar: Calendar = .current, topCount: Int = 3) {
        let consumed = history.filter { $0.consumedAt != nil }
        consumedCount = consumed.count

        var counts: [String: (name: String, count: Int, latest: Date)] = [:]
        for item in consumed {
            let key = FoodNameKey.normalize(item.name)
            let date = item.consumedAt ?? .distantPast
            let existing = counts[key]
            counts[key] = (existing.map { $0.latest >= date ? $0.name : item.name } ?? item.name,
                           (existing?.count ?? 0) + 1, max(existing?.latest ?? .distantPast, date))
        }
        topNames = counts.values
            .sorted { ($0.count, $0.latest) > ($1.count, $1.latest) }
            .prefix(topCount)
            .map { NameCount(name: $0.name, count: $0.count) }

        let dates = FoodDateCalculator(calendar: calendar)
        let durations = consumed.compactMap { item in item.consumedAt.map { dates.daysStored(since: item.storedAt, now: $0) } }
        averageStorageDays = durations.isEmpty ? nil : Double(durations.reduce(0, +)) / Double(durations.count)
    }
}
