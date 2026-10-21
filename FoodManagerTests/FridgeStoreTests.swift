import SwiftData
import XCTest
@testable import FoodManager

final class FridgeStoreTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("test.store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    /// A fresh store over the same file simulates an app relaunch.
    private func makeStore() throws -> SwiftDataFridgeStore {
        SwiftDataFridgeStore(container: try SwiftDataFridgeStore.makeContainer(url: storeURL))
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let fridge = FridgeFactory.makeDefault()
        let decoded = try StoredLayout.decode(StoredLayout.encode(fridge))
        XCTAssertEqual(decoded.version, StoredLayout.currentVersion)
        XCTAssertEqual(decoded.cabinetCompartments, fridge.cabinetCompartments)
        XCTAssertEqual(decoded.doorCompartments, fridge.doorCompartments)
    }

    func testCreatesDefaultFridgeOnceAndReloadsIt() throws {
        let first = try makeStore().loadOrCreateFridge()
        let second = try makeStore().loadOrCreateFridge()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.templateID, FridgeTemplate.standardSingleDoor.id)
    }

    func testSavedLayoutAndDoorStateSurviveRelaunch() throws {
        let store = try makeStore()
        let fridge = try store.loadOrCreateFridge()
        let editor = FridgeLayoutEditor(fridge: fridge)
        try editor.rename(fridge.cabinetCompartments[0].id, to: "飲料")
        try editor.delete(fridge.doorCompartments[2].id)
        try store.saveLayout(editor.commit())
        try store.saveDoorState(.open, fridgeID: fridge.id)

        let reloaded = try makeStore().loadOrCreateFridge()
        XCTAssertEqual(reloaded.cabinetCompartments[0].name, "飲料")
        XCTAssertEqual(reloaded.doorCompartments.count, 2)
        XCTAssertEqual(reloaded.lastDoorState, .open)
        XCTAssertEqual(reloaded.allCompartments.map(\.id), editor.working.allCompartments.map(\.id), "IDs are stable")
    }

    func testCancelledEditIsNeverPersisted() throws {
        let store = try makeStore()
        let fridge = try store.loadOrCreateFridge()
        let editor = FridgeLayoutEditor(fridge: fridge)
        try editor.delete(fridge.cabinetCompartments[0].id)
        // Cancel = drop the editor without saving.
        XCTAssertEqual(try makeStore().loadOrCreateFridge(), fridge)
    }

    func testRejectsInvalidLayoutAndKeepsPreviousState() throws {
        let store = try makeStore()
        var fridge = try store.loadOrCreateFridge()
        let original = fridge
        fridge.cabinetCompartments[1].normalizedFrame.y = 0 // overlaps the first shelf
        XCTAssertThrowsError(try store.saveLayout(fridge)) { error in
            guard case FridgeStoreError.invalidLayout = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try makeStore().loadOrCreateFridge(), original)
    }

    func testDeletingAllCompartmentsIsPreserved() throws {
        let store = try makeStore()
        var fridge = try store.loadOrCreateFridge()
        fridge.doorCompartments = []
        try store.saveLayout(fridge)
        XCTAssertEqual(try makeStore().loadOrCreateFridge().doorCompartments, [])
    }
}
