import SwiftData
import XCTest
@testable import FoodManager

/// 10–11: damaged stored layouts are recovered without losing food links or rewriting data silently.
final class LayoutRecoveryTests: XCTestCase {
    private var container: ModelContainer!
    private let fridgeID = UUID()

    override func setUpWithError() throws {
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
    }

    private func seed(layoutData: Data) throws {
        let context = ModelContext(container)
        context.insert(FridgeRecord(id: fridgeID, name: "我的冰箱", templateID: FridgeTemplate.standardSingleDoor.id,
                                    lastDoorStateRaw: DoorState.open.rawValue, layoutData: layoutData))
        try context.save()
    }

    private func storedBytes() throws -> Data? {
        try ModelContext(container).fetch(FetchDescriptor<FridgeRecord>()).first?.layoutData
    }

    private func inventory(for fridge: Fridge) -> FoodInventoryService {
        FoodInventoryService(store: SwiftDataFoodStore(container: container), fridgeID: fridge.id,
                             compartments: { fridge.allCompartments })
    }

    func testInvalidLayoutIsRepairedKeepingCompartmentIDsAndFood() throws {
        var damaged = FridgeFactory.makeDefault()
        damaged.cabinetCompartments[1].normalizedFrame.y = 0          // overlap
        damaged.cabinetCompartments[2].normalizedFrame.height = 0.9   // overflow
        damaged.cabinetCompartments[3].storageType = .frozen          // valid frozen must stay frozen
        let ids = damaged.allCompartments.map(\.id)
        let bytes = try StoredLayout.encode(damaged)
        try seed(layoutData: bytes)

        let result = try SwiftDataFridgeStore(container: container).load()
        XCTAssertEqual(result.recovery, .repaired)
        XCTAssertEqual(result.fridge.allCompartments.map(\.id), ids, "IDs preserved, so food stays attached")
        XCTAssertEqual(result.fridge.cabinetCompartments[3].storageType, .frozen)
        XCTAssertEqual(FridgeLayoutEngine.validate(result.fridge), [])
        XCTAssertEqual(try storedBytes(), bytes, "original bytes untouched until the user confirms")
    }

    func testUndecodableLayoutUsesDeterministicDefaultIDs() throws {
        let garbage = Data("not json".utf8)
        try seed(layoutData: garbage)
        let first = try SwiftDataFridgeStore(container: container).load()
        let second = try SwiftDataFridgeStore(container: container).load()
        XCTAssertEqual(first.recovery, .replacedWithDefault)
        XCTAssertEqual(first.fridge.allCompartments.map(\.id), second.fridge.allCompartments.map(\.id),
                       "no endless series of new replacement IDs")
        XCTAssertEqual(first.fridge.lastDoorState, .open, "door state survives")
        XCTAssertEqual(try storedBytes(), garbage)
    }

    func testMultipleAffectedFoodsAreKeptForManualReassignment() throws {
        try seed(layoutData: Data("{broken".utf8))
        let fridge = try SwiftDataFridgeStore(container: container).load().fridge
        let foodStore = SwiftDataFoodStore(container: container)
        let lostShelf = UUID(), lostFreezer = UUID()
        let now = Date()
        for (name, compartment) in [("牛奶", lostShelf), ("水餃", lostFreezer), ("冰淇淋", lostFreezer)] {
            try foodStore.upsert(FoodItem(id: UUID(), name: name, categoryID: "other", quantity: 1, unit: "個",
                                          storedAt: now, fridgeID: fridge.id, compartmentID: compartment,
                                          createdAt: now, updatedAt: now))
        }
        let inventory = inventory(for: fridge)
        XCTAssertEqual(inventory.items.count, 3, "nothing discarded")
        XCTAssertEqual(Set(inventory.itemsWithMissingCompartment.map(\.name)), ["牛奶", "水餃", "冰淇淋"])
        XCTAssertTrue(inventory.items.allSatisfy { $0.compartmentID == lostShelf || $0.compartmentID == lostFreezer },
                      "no automatic reassignment (frozen food is never moved into refrigerated storage on its own)")

        // The user reassigns one item explicitly.
        let dumplings = try XCTUnwrap(inventory.items.first { $0.name == "水餃" })
        try inventory.move(dumplings.id, to: fridge.cabinetCompartments[0].id)
        XCTAssertEqual(inventory.itemsWithMissingCompartment.count, 2)
    }

    func testConfirmingRecoveryPersistsTheRepairedLayout() throws {
        try seed(layoutData: Data("{broken".utf8))
        let store = SwiftDataFridgeStore(container: container)
        let recovered = try store.load()
        try store.saveLayout(recovered.fridge) // what "儲存目前隔層" does after confirmation
        let reloaded = try SwiftDataFridgeStore(container: container).load()
        XCTAssertEqual(reloaded.recovery, .none)
        XCTAssertEqual(reloaded.fridge, recovered.fridge)
    }

    func testRepairHandlesDuplicatesNamesAndWrongZoneTypes() {
        let shared = UUID()
        func compartment(_ id: UUID, _ type: CompartmentType, _ storage: StorageType, name: String) -> Compartment {
            Compartment(id: id, parentZoneID: .door, name: name, type: type, storageType: storage, sortOrder: 0,
                        normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.3))
        }
        let repaired = FridgeLayoutRepair.repair([compartment(shared, .shelf, .unspecified, name: "  "),
                                                  compartment(shared, .drawer, .refrigerated, name: "B")], in: .cabinet)
        let result = try? XCTUnwrap(repaired)
        XCTAssertEqual(result?.count, 2, "nothing dropped")
        XCTAssertEqual(result?.first?.id, shared)
        XCTAssertNotEqual(result?.last?.id, shared)
        XCTAssertEqual(result?.first?.storageType, .refrigerated, "only an invalid classification is replaced")
        XCTAssertTrue(result?.allSatisfy { $0.parentZoneID == .cabinet && FridgeLayoutEngine.isValidName($0.name) } ?? false)
        XCTAssertEqual(FridgeLayoutRepair.repair([compartment(shared, .shelf, .unspecified, name: "x")], in: .cabinet)?.first?.id,
                       FridgeLayoutRepair.repair([compartment(shared, .shelf, .unspecified, name: "x")], in: .cabinet)?.first?.id)
    }

    func testTooManyCompartmentsFallBackInsteadOfDropping() {
        let many = (0..<12).map { i in
            Compartment(id: UUID(), parentZoneID: .cabinet, name: "S\(i)", type: .shelf, storageType: .refrigerated,
                        sortOrder: i, normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.2))
        }
        XCTAssertNil(FridgeLayoutRepair.repair(many, in: .cabinet))
    }
}
