import XCTest
@testable import FoodManager

final class FridgeLayoutEditorTests: XCTestCase {
    private var fridge: Fridge!
    private var editor: FridgeLayoutEditor!

    override func setUp() {
        super.setUp()
        fridge = FridgeFactory.makeDefault()
        editor = FridgeLayoutEditor(fridge: fridge)
    }

    private var firstShelf: Compartment { editor.working.cabinetCompartments[0] }

    func testStartsWithoutChanges() {
        XCTAssertFalse(editor.hasChanges)
        XCTAssertEqual(editor.working, fridge)
    }

    func testAddRequiresSpaceAndRejectsWhenFull() throws {
        // Default cabinet is nearly full: adding must fail until something shrinks.
        XCTAssertThrowsError(try editor.addCompartment(type: .shelf, to: .cabinet)) {
            XCTAssertEqual($0 as? LayoutEditError, .notEnoughSpace)
        }
        try editor.delete(firstShelf.id)
        let added = try editor.addCompartment(type: .shelf, to: .cabinet)
        XCTAssertEqual(editor.working.cabinetCompartments.last?.id, added.id)
        XCTAssertEqual(FridgeLayoutEngine.validate(editor.working), [])
    }

    func testAddRejectsTypeInWrongZone() {
        XCTAssertThrowsError(try editor.addCompartment(type: .doorShelf, to: .cabinet)) {
            XCTAssertEqual($0 as? LayoutEditError, .typeNotAllowed(.doorShelf, .cabinet))
        }
        XCTAssertThrowsError(try editor.addCompartment(type: .drawer, to: .door))
    }

    func testDoorAndCabinetEditsAreIndependent() throws {
        let doorBefore = editor.working.doorCompartments
        try editor.resize(firstShelf.id, by: -0.04)
        XCTAssertEqual(editor.working.doorCompartments, doorBefore)
    }

    func testRenameTrimsAndValidates() throws {
        try editor.rename(firstShelf.id, to: "  飲料  ")
        XCTAssertEqual(firstShelf.name, "飲料")
        XCTAssertThrowsError(try editor.rename(firstShelf.id, to: "  ")) {
            XCTAssertEqual($0 as? LayoutEditError, .invalidName)
        }
        XCTAssertThrowsError(try editor.rename(firstShelf.id, to: String(repeating: "長", count: 30)))
        XCTAssertEqual(firstShelf.name, "飲料")
    }

    func testMoveSwapsOrderAndKeepsIDsStable() throws {
        let ids = editor.working.cabinetCompartments.map(\.id)
        try editor.move(ids[0], .down)
        XCTAssertEqual(editor.working.cabinetCompartments.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(editor.working.cabinetCompartments.map(\.sortOrder), [0, 1, 2, 3])
        XCTAssertEqual(editor.working.cabinetCompartments[0].normalizedFrame.y, 0)
        // Edges are no-ops, not errors.
        try editor.move(ids[1], .up)
        XCTAssertEqual(editor.working.cabinetCompartments.first?.id, ids[1])
        XCTAssertEqual(FridgeLayoutEngine.validate(editor.working), [])
    }

    func testResizeEnforcesMinimumAndBounds() throws {
        let id = firstShelf.id
        try editor.resize(id, by: -0.04)
        XCTAssertEqual(firstShelf.normalizedFrame.height, 0.18, accuracy: 1e-9)
        XCTAssertThrowsError(try editor.setHeight(id, to: FridgeLayoutEngine.minHeight - 0.02)) {
            XCTAssertEqual($0 as? LayoutEditError, .belowMinimumHeight)
        }
        XCTAssertThrowsError(try editor.resize(id, by: 0.5)) {
            XCTAssertEqual($0 as? LayoutEditError, .notEnoughSpace)
        }
        // A failed edit leaves the working copy untouched.
        XCTAssertEqual(firstShelf.normalizedFrame.height, 0.18, accuracy: 1e-9)
    }

    func testDeleteRemovesAndRepacks() throws {
        let id = firstShelf.id
        try editor.delete(id)
        XCTAssertNil(editor.compartment(id: id))
        XCTAssertEqual(editor.working.cabinetCompartments.count, 3)
        XCTAssertEqual(editor.working.cabinetCompartments[0].normalizedFrame.y, 0)
    }

    func testDeleteRefusesOccupiedCompartment() {
        struct OneItem: CompartmentOccupancyProviding { func itemCount(in compartmentID: UUID) -> Int { 1 } }
        let editor = FridgeLayoutEditor(fridge: fridge, occupancy: OneItem())
        let id = fridge.cabinetCompartments[0].id
        XCTAssertThrowsError(try editor.delete(id)) {
            XCTAssertEqual($0 as? LayoutEditError, .compartmentOccupied(itemCount: 1))
        }
        XCTAssertNotNil(editor.compartment(id: id))
    }

    func testCancelLeavesOriginalUntouched() throws {
        try editor.rename(firstShelf.id, to: "改名")
        try editor.delete(editor.working.doorCompartments[0].id)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(editor.original, fridge, "working copy must be isolated from the original")
        XCTAssertEqual(fridge.doorCompartments.count, 3)
    }

    func testCommitReturnsValidatedWorkingCopy() throws {
        try editor.rename(firstShelf.id, to: "改名")
        let committed = try editor.commit()
        XCTAssertEqual(committed.cabinetCompartments[0].name, "改名")
        XCTAssertEqual(FridgeLayoutEngine.validate(committed), [])
    }
}
