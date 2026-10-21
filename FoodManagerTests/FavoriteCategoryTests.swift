import XCTest
@testable import FoodManager

/// 20-category catalog, pinned favorites (max 5, user order), picker sections and persistence.
final class FavoriteCategoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FavoriteCategoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var catalogIDs: [String] { FoodCategoryCatalog.all.map(\.id) }

    func testAllTwentyCategoriesExistWithUniqueIDsNamesAndAssets() {
        XCTAssertEqual(FoodCategoryCatalog.all.count, 20)
        XCTAssertEqual(Set(catalogIDs).count, 20)
        XCTAssertEqual(Set(FoodCategoryCatalog.all.map(\.displayName)).count, 20)
        XCTAssertEqual(Set(FoodCategoryCatalog.all.map(\.assetName)).count, 20)
        XCTAssertEqual(catalogIDs.last, FoodCategoryCatalog.otherID, "其他 stays last")
    }

    func testPhase2CategoryIDsAreStillValid() {
        let phase2IDs = ["leafy-greens", "root-vegetables", "fruiting-vegetables", "mushrooms", "fruits", "meat", "poultry",
                         "seafood", "eggs", "dairy", "beverages", "frozen-foods", "prepared-foods", "condiments", "other"]
        for id in phase2IDs {
            XCTAssertTrue(FoodCategoryCatalog.contains(id), id)
            XCTAssertEqual(FoodCategoryCatalog.category(id: id).id, id, id)
        }
        // frozen-foods keeps its ID and asset; only the wording changed to "prepared frozen food".
        XCTAssertEqual(FoodCategoryCatalog.category(id: "frozen-foods").displayName, "冷凍調理食品")
        XCTAssertEqual(FoodCategoryCatalog.category(id: "frozen-foods").assetName, "category_frozen_foods")
    }

    func testExistingFoodRecordsKeepValidCategoryReferences() throws {
        var fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments[0].storageType = .refrigerated
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let inventory = FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                                             compartments: { fridge.allCompartments })
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = "水餃"
        draft.categoryID = "frozen-foods"
        let dumplings = try inventory.add(draft)
        draft.name = "豆腐"
        draft.categoryID = "soy-products"
        try inventory.add(draft)
        let reloaded = FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                                            compartments: { fridge.allCompartments })
        XCTAssertEqual(reloaded.item(id: dumplings.id)?.categoryID, "frozen-foods")
        XCTAssertTrue(reloaded.items.allSatisfy { FoodCategoryCatalog.contains($0.categoryID) })
    }

    func testNoFavoritesShowsCatalogOrder() {
        let sections = CategoryPickerSections(favorites: FavoriteCategories())
        XCTAssertTrue(sections.favorites.isEmpty)
        XCTAssertEqual(sections.others.map(\.id), catalogIDs)
    }

    func testFavoritesFirstInPinOrderOthersKeepCatalogOrderWithoutDuplicates() throws {
        var favorites = FavoriteCategories()
        for id in ["dairy", "leafy-greens", "beverages"] { try favorites.pin(id) }
        let sections = CategoryPickerSections(favorites: favorites)
        XCTAssertEqual(sections.favorites.map(\.id), ["dairy", "leafy-greens", "beverages"], "user's pin order, not catalog order")
        XCTAssertEqual(sections.others.map(\.id), catalogIDs.filter { !favorites.contains($0) })
        let all = sections.favorites.map(\.id) + sections.others.map(\.id)
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(Set(all).count, 20, "no category appears twice")
    }

    func testFavoriteLimitIsEnforced() throws {
        var favorites = FavoriteCategories()
        for id in catalogIDs.prefix(5) { try favorites.pin(id) }
        XCTAssertThrowsError(try favorites.pin(catalogIDs[5])) {
            XCTAssertEqual($0 as? FavoriteCategoryError, .limitReached)
        }
        XCTAssertEqual(favorites.ids, Array(catalogIDs.prefix(5)))
        XCTAssertNoThrow(try favorites.pin(catalogIDs[0]), "re-pinning an existing favorite is a no-op")
        XCTAssertThrowsError(try favorites.pin("not-a-category"))
        // Corrupt or oversized stored lists are sanitized.
        XCTAssertEqual(FavoriteCategories(ids: ["eggs", "eggs", "bogus"] + catalogIDs).ids.count, 5)
        XCTAssertEqual(FavoriteCategories(ids: ["eggs", "eggs", "bogus", "meat"]).ids, ["eggs", "meat"])
    }

    func testUnpinRestoresDefaultOrdering() throws {
        var favorites = FavoriteCategories()
        try favorites.pin("meat")
        try favorites.pin("eggs")
        favorites.unpin("meat")
        XCTAssertEqual(favorites.ids, ["eggs"])
        favorites.unpin("eggs")
        XCTAssertEqual(CategoryPickerSections(favorites: favorites).others.map(\.id), catalogIDs)
    }

    func testSearchFiltersBothSections() throws {
        var favorites = FavoriteCategories()
        try favorites.pin("meat")
        let sections = CategoryPickerSections(favorites: favorites, query: "肉")
        XCTAssertEqual(sections.favorites.map(\.id), ["meat"])
        XCTAssertEqual(sections.others.map(\.id), ["poultry"])
        XCTAssertTrue(CategoryPickerSections(favorites: favorites, query: "披薩").isEmpty)
        XCTAssertEqual(CategoryPickerSections(favorites: favorites, query: "  ").others.count, 19)
    }

    func testFavoritesPersistAcrossRelaunch() throws {
        let store = UserDefaultsFavoriteCategoryStore(defaults: defaults)
        XCTAssertEqual(store.load(), FavoriteCategories())
        var favorites = store.load()
        try favorites.pin("beverages")
        try favorites.pin("dairy")
        store.save(favorites)

        let relaunched = UserDefaultsFavoriteCategoryStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(relaunched.load().ids, ["beverages", "dairy"])
    }

    func testFoodDraftStillDefaultsToOther() {
        XCTAssertEqual(FoodDraft().categoryID, FoodCategoryCatalog.otherID)
    }

    func testPlaceholderGlyphsAreUnique() {
        XCTAssertEqual(Set(FoodCategoryCatalog.all.map(\.placeholderGlyph)).count, 20)
    }
}
