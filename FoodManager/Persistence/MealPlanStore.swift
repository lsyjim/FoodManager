import Foundation
import SwiftData

/// One planned dish (每週餐桌). Its ingredients are a versioned JSON list inside the row, so a dish is always saved
/// in one write and its ingredient IDs stay stable. Added in Phase 5I as a new entity (lightweight migration; no
/// existing row is touched). All attributes have defaults, like every other model of this store.
@Model
final class PlannedDishRecord {
    var id: UUID = UUID()
    var day: String = ""
    var mealRaw: String = MealType.dinner.rawValue
    var title: String = ""
    var sortOrder: Int = 0
    var isCompleted: Bool = false
    var ingredientsData: Data = Data()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(_ dish: PlannedDish) {
        id = dish.id
        apply(dish)
    }

    func apply(_ dish: PlannedDish) {
        day = dish.day.value
        mealRaw = dish.meal.rawValue
        title = dish.title
        sortOrder = dish.sortOrder
        isCompleted = dish.isCompleted
        ingredientsData = (try? JSONEncoder().encode(dish.ingredients)) ?? Data()
        createdAt = dish.createdAt
        updatedAt = dish.updatedAt
    }

    var dish: PlannedDish {
        PlannedDish(id: id, day: DayKey(day), meal: MealType(rawValue: mealRaw) ?? .dinner, title: title, sortOrder: sortOrder,
                    isCompleted: isCompleted, ingredients: (try? JSONDecoder().decode([PlannedIngredient].self, from: ingredientsData)) ?? [],
                    createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// One shopping-list entry (購物清單). Never an inventory record.
@Model
final class ShoppingItemRecord {
    var id: UUID = UUID()
    var name: String = ""
    var categoryID: String?
    var quantityText: String?
    var unit: String?
    var isPurchased: Bool = false
    var purchasedAt: Date?
    var sourceKey: String?
    var isUserEdited: Bool = false
    var storedFoodID: UUID?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(_ item: ShoppingItem) {
        id = item.id
        apply(item)
    }

    func apply(_ item: ShoppingItem) {
        name = item.name
        categoryID = item.categoryID
        quantityText = item.quantityText
        unit = item.unit
        isPurchased = item.isPurchased
        purchasedAt = item.purchasedAt
        sourceKey = item.sourceKey
        isUserEdited = item.isUserEdited
        storedFoodID = item.storedFoodID
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }

    var item: ShoppingItem {
        ShoppingItem(id: id, name: name, categoryID: categoryID, quantityText: quantityText, unit: unit, isPurchased: isPurchased,
                     purchasedAt: purchasedAt, sourceKey: sourceKey, isUserEdited: isUserEdited, storedFoodID: storedFoodID,
                     createdAt: createdAt, updatedAt: updatedAt)
    }
}

enum MealPlanStoreError: Error, Equatable {
    case invalid(String)
    case notFound

    var message: String {
        switch self {
        case let .invalid(message): return message
        case .notFound: return "找不到這筆資料，可能已被刪除。"
        }
    }
}

protocol MealPlanStore: AnyObject {
    func dishes(from start: DayKey, through end: DayKey) throws -> [PlannedDish]
    func allDishes() throws -> [PlannedDish]
    func save(_ dish: PlannedDish) throws
    func save(_ dishes: [PlannedDish]) throws
    func deleteDish(id: UUID) throws

    func shoppingItems() throws -> [ShoppingItem]
    func save(_ item: ShoppingItem) throws
    func save(_ items: [ShoppingItem]) throws
    func deleteShoppingItem(id: UUID) throws
}

/// Personal store (the same local-only SwiftData store as fridges and food). A fresh context per call; every write
/// is one save (all or nothing) and posts a change notification only after it succeeded.
final class SwiftDataMealPlanStore: MealPlanStore {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    // MARK: Dishes

    func dishes(from start: DayKey, through end: DayKey) throws -> [PlannedDish] {
        let low = start.value, high = end.value
        return try makeContext().fetch(FetchDescriptor<PlannedDishRecord>(predicate: #Predicate { $0.day >= low && $0.day <= high }))
            .map(\.dish).sorted(by: Self.dishOrder)
    }

    func allDishes() throws -> [PlannedDish] {
        try makeContext().fetch(FetchDescriptor<PlannedDishRecord>()).map(\.dish).sorted(by: Self.dishOrder)
    }

    func save(_ dish: PlannedDish) throws { try save([dish]) }

    func save(_ dishes: [PlannedDish]) throws {
        for dish in dishes { try Self.validate(dish) }
        let context = makeContext()
        for dish in dishes {
            let id = dish.id
            let rows = try context.fetch(FetchDescriptor<PlannedDishRecord>(predicate: #Predicate { $0.id == id }))
            if rows.isEmpty { context.insert(PlannedDishRecord(dish)) } else { rows.forEach { $0.apply(dish) } }
        }
        try commit(context, .mealPlanDidChange)
    }

    func deleteDish(id: UUID) throws {
        let context = makeContext()
        let rows = try context.fetch(FetchDescriptor<PlannedDishRecord>(predicate: #Predicate { $0.id == id }))
        guard !rows.isEmpty else { throw MealPlanStoreError.notFound }
        rows.forEach(context.delete)
        try commit(context, .mealPlanDidChange)
    }

    // MARK: Shopping

    func shoppingItems() throws -> [ShoppingItem] {
        try makeContext().fetch(FetchDescriptor<ShoppingItemRecord>(sortBy: [SortDescriptor(\.createdAt)])).map(\.item)
    }

    func save(_ item: ShoppingItem) throws { try save([item]) }

    func save(_ items: [ShoppingItem]) throws {
        for item in items { try Self.validate(item) }
        let context = makeContext()
        for item in items {
            let id = item.id
            let rows = try context.fetch(FetchDescriptor<ShoppingItemRecord>(predicate: #Predicate { $0.id == id }))
            if rows.isEmpty { context.insert(ShoppingItemRecord(item)) } else { rows.forEach { $0.apply(item) } }
        }
        try commit(context, .shoppingListDidChange)
    }

    func deleteShoppingItem(id: UUID) throws {
        let context = makeContext()
        let rows = try context.fetch(FetchDescriptor<ShoppingItemRecord>(predicate: #Predicate { $0.id == id }))
        guard !rows.isEmpty else { throw MealPlanStoreError.notFound }
        rows.forEach(context.delete)
        try commit(context, .shoppingListDidChange)
    }

    // MARK: Helpers

    private func commit(_ context: ModelContext, _ notification: Notification.Name) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func dishOrder(_ a: PlannedDish, _ b: PlannedDish) -> Bool {
        (a.day, a.meal, a.sortOrder, a.id.uuidString) < (b.day, b.meal, b.sortOrder, b.id.uuidString)
    }

    static func validate(_ dish: PlannedDish) throws {
        let title = dish.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MealPlanStoreError.invalid("請輸入菜名") }
        guard title.count <= PlannedDish.maxTitleLength else { throw MealPlanStoreError.invalid("菜名最多 \(PlannedDish.maxTitleLength) 字") }
        guard dish.day.isValid else { throw MealPlanStoreError.invalid("日期無效") }
        guard dish.ingredients.count <= PlannedDish.maxIngredients else {
            throw MealPlanStoreError.invalid("每道菜最多 \(PlannedDish.maxIngredients) 項食材")
        }
        for ingredient in dish.ingredients {
            let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= FoodValidationError.maxNameLength else {
                throw MealPlanStoreError.invalid("食材名稱需為 1–\(FoodValidationError.maxNameLength) 字")
            }
            if let quantity = ingredient.quantity, !(quantity > 0 && quantity <= 1_000_000) {
                throw MealPlanStoreError.invalid("「\(name)」的數量需大於 0")
            }
            if ingredient.quantityText != nil && ingredient.quantity == nil { throw MealPlanStoreError.invalid("「\(name)」的數量無效") }
            if (ingredient.unit?.count ?? 0) > FoodValidationError.maxUnitLength {
                throw MealPlanStoreError.invalid("單位最多 \(FoodValidationError.maxUnitLength) 字")
            }
        }
    }

    static func validate(_ item: ShoppingItem) throws {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= ShoppingItem.maxNameLength else {
            throw MealPlanStoreError.invalid("品項名稱需為 1–\(ShoppingItem.maxNameLength) 字")
        }
        if let quantity = item.quantity, !(quantity > 0 && quantity <= 1_000_000) { throw MealPlanStoreError.invalid("數量需大於 0") }
        if item.quantityText != nil && item.quantity == nil { throw MealPlanStoreError.invalid("數量無效") }
        if (item.unit?.count ?? 0) > FoodValidationError.maxUnitLength {
            throw MealPlanStoreError.invalid("單位最多 \(FoodValidationError.maxUnitLength) 字")
        }
    }
}
