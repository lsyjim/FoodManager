import XCTest
@testable import FoodManager

/// Phase 1.1: refrigerated / frozen classification is independent of physical structure and position.
final class StorageTypeEditingTests: XCTestCase {
    private var fridge: Fridge!
    private var editor: FridgeLayoutEditor!

    override func setUp() {
        super.setUp()
        // Start from an empty cabinet so every add has room; the door keeps its three default shelves.
        fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments = []
        editor = FridgeLayoutEditor(fridge: fridge)
    }

    private var cabinet: [Compartment] { editor.working.cabinetCompartments }

    // 1–4: the four cabinet add options.
    func testAddEachCabinetOptionCreatesMatchingTypeAndStorage() throws {
        let expected: [(AddCompartmentOption, CompartmentType, StorageType)] = [
            (.refrigeratedShelf, .shelf, .refrigerated),
            (.frozenShelf, .shelf, .frozen),
            (.refrigeratedDrawer, .drawer, .refrigerated),
            (.frozenDrawer, .drawer, .frozen),
        ]
        for (option, type, storage) in expected {
            let added = try editor.addCompartment(option)
            XCTAssertEqual(added.type, type)
            XCTAssertEqual(added.storageType, storage)
            XCTAssertEqual(added.parentZoneID, .cabinet)
        }
        XCTAssertEqual(cabinet.map(\.name), ["冷藏層架 1", "冷凍層架 1", "冷藏抽屜 1", "冷凍抽屜 1"])
        XCTAssertEqual(FridgeLayoutEngine.validate(editor.working), [])
    }

    // 5 & 10: door shelves are unclassified and live only in the door zone.
    func testAddDoorShelfIsUnspecifiedAndIndependentOfCabinet() throws {
        try editor.deleteAllDoorShelves()
        try editor.addCompartment(.refrigeratedShelf)
        let cabinetBefore = cabinet
        let door = try editor.addCompartment(.doorShelf)
        XCTAssertEqual(door.type, .doorShelf)
        XCTAssertEqual(door.storageType, .unspecified)
        XCTAssertEqual(door.parentZoneID, .door)
        XCTAssertEqual(editor.working.doorCompartments.map(\.id), [door.id])
        XCTAssertEqual(cabinet, cabinetBefore, "adding to the door must not touch the cabinet")
    }

    func testDoorShelfCannotBeClassified() throws {
        let door = editor.working.doorCompartments[0]
        XCTAssertThrowsError(try editor.setStorageType(door.id, to: .frozen)) {
            XCTAssertEqual($0 as? LayoutEditError, .storageTypeNotAllowed(.frozen, .door))
        }
        XCTAssertThrowsError(try editor.addCompartment(type: .shelf, storage: .unspecified, to: .cabinet))
    }

    // 6, 7, 17: reclassifying keeps identity, position and size.
    func testChangingStorageTypeKeepsIdentityAndPosition() throws {
        let shelf = try editor.addCompartment(.refrigeratedShelf)
        let drawer = try editor.addCompartment(.frozenDrawer)
        let framesBefore = cabinet.map(\.normalizedFrame)

        try editor.setStorageType(shelf.id, to: .frozen)
        try editor.setStorageType(drawer.id, to: .refrigerated)

        XCTAssertEqual(editor.compartment(id: shelf.id)?.storageType, .frozen)
        XCTAssertEqual(editor.compartment(id: drawer.id)?.storageType, .refrigerated)
        XCTAssertEqual(cabinet.map(\.id), [shelf.id, drawer.id])
        XCTAssertEqual(cabinet.map(\.normalizedFrame), framesBefore)
        XCTAssertEqual(cabinet.map(\.name), [shelf.name, drawer.name])
    }

    // 8: configurations A, B and C from the spec all keep the user's order.
    func testMixedTemperatureOrderIsPreservedAsEntered() throws {
        let configurations: [[AddCompartmentOption]] = [
            [.refrigeratedShelf, .refrigeratedShelf, .frozenDrawer, .frozenDrawer],
            [.frozenShelf, .frozenShelf, .refrigeratedShelf, .refrigeratedDrawer],
            [.refrigeratedShelf, .frozenDrawer, .refrigeratedShelf, .frozenShelf],
        ]
        for options in configurations {
            let editor = FridgeLayoutEditor(fridge: fridge)
            for option in options { try editor.addCompartment(option) }
            let result = editor.working.cabinetCompartments
            XCTAssertEqual(result.map(\.storageType), options.map(\.storageType))
            XCTAssertEqual(result.map(\.type), options.map(\.type))
            let ys = result.map(\.normalizedFrame.y)
            XCTAssertEqual(ys, ys.sorted(), "positions follow user order, not temperature")
            XCTAssertEqual(FridgeLayoutEngine.validate(editor.working), [])
        }
    }

    // 9: moving never changes classification.
    func testReorderingDoesNotChangeStorageType() throws {
        let frozen = try editor.addCompartment(.frozenShelf)
        let chilled = try editor.addCompartment(.refrigeratedDrawer)
        try editor.move(chilled.id, .up)
        XCTAssertEqual(cabinet.map(\.id), [chilled.id, frozen.id])
        XCTAssertEqual(cabinet.map(\.storageType), [.refrigerated, .frozen])
    }

    // 13: cancel = original untouched.
    func testCancelRestoresOriginalAfterStorageEdits() throws {
        let original = FridgeFactory.makeDefault()
        let editor = FridgeLayoutEditor(fridge: original)
        try editor.setStorageType(original.cabinetCompartments[0].id, to: .frozen)
        try editor.delete(original.cabinetCompartments[3].id)
        try editor.addCompartment(.frozenDrawer)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(editor.original, original)
        XCTAssertEqual(original.cabinetCompartments.map(\.storageType), Array(repeating: .refrigerated, count: 4))
    }

    // 14–16: overlap-free packing, minimum size, insufficient space leaves layout unchanged.
    func testInsufficientSpaceRejectsWithoutChangingLayout() throws {
        for _ in 0..<4 { try editor.addCompartment(.frozenShelf) }
        let before = editor.working
        XCTAssertThrowsError(try editor.addCompartment(.refrigeratedDrawer)) {
            XCTAssertEqual($0 as? LayoutEditError, .notEnoughSpace)
            XCTAssertEqual(($0 as? LayoutEditError)?.message, "空間不足")
        }
        XCTAssertEqual(editor.working, before)
        XCTAssertFalse(FridgeLayoutEngine.validate(cabinet, in: .cabinet).contains { if case .overlap = $0 { return true }; return false })
    }

    func testCannotShrinkBelowMinimumHeight() throws {
        let shelf = try editor.addCompartment(.frozenShelf)
        XCTAssertThrowsError(try editor.setHeight(shelf.id, to: FridgeLayoutEngine.minHeight - 0.01)) {
            XCTAssertEqual($0 as? LayoutEditError, .belowMinimumHeight)
        }
        try editor.setHeight(shelf.id, to: FridgeLayoutEngine.minHeight)
        XCTAssertEqual(editor.compartment(id: shelf.id)?.normalizedFrame.height, FridgeLayoutEngine.minHeight)
    }

    func testValidationRejectsUnclassifiedCabinetCompartment() {
        var bad = FridgeFactory.makeDefault()
        bad.cabinetCompartments[0].storageType = .unspecified
        XCTAssertEqual(FridgeLayoutEngine.validate(bad), [.storageTypeNotAllowed(bad.cabinetCompartments[0].id)])
    }

    func testValidationRejectsInconsistentSortOrder() {
        var bad = FridgeFactory.makeDefault()
        bad.cabinetCompartments[1].sortOrder = 0
        XCTAssertTrue(FridgeLayoutEngine.validate(bad).contains(.invalidOrder(bad.cabinetCompartments[1].id)))
    }
}

private extension FridgeLayoutEditor {
    func deleteAllDoorShelves() throws {
        for shelf in working.doorCompartments { try delete(shelf.id) }
    }
}
