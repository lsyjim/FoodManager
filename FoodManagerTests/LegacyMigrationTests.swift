import SwiftData
import XCTest
@testable import FoodManager

/// Phase 1 data (layout v1: no storageType, door typed "doorRack") must load intact under Phase 1.1.
final class LegacyMigrationTests: XCTestCase {
    private let shelfID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let drawerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let rackID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// Byte-for-byte shape of what the Phase 1 build wrote (sorted keys, version 1).
    private var legacyJSON: Data {
        Data("""
        {"cabinetCompartments":[\
        {"id":"\(shelfID)","name":"飲料","normalizedFrame":{"height":0.3,"width":1,"x":0,"y":0},\
        "parentZoneID":"cabinet","sortOrder":0,"type":"shelf"},\
        {"id":"\(drawerID)","name":"抽屜 2","normalizedFrame":{"height":0.12,"width":1,"x":0,"y":0.315},\
        "parentZoneID":"cabinet","sortOrder":1,"type":"drawer"}],\
        "doorCompartments":[\
        {"id":"\(rackID)","name":"門架 1","normalizedFrame":{"height":0.28,"width":1,"x":0,"y":0},\
        "parentZoneID":"door","sortOrder":0,"type":"doorRack"}],\
        "version":1}
        """.utf8)
    }

    func testDecodesV1LayoutWithDefaults() throws {
        let layout = try StoredLayout.decode(legacyJSON)
        XCTAssertEqual(layout.version, 1)
        XCTAssertEqual(layout.cabinetCompartments.map(\.id), [shelfID, drawerID])
        XCTAssertEqual(layout.cabinetCompartments.map(\.name), ["飲料", "抽屜 2"])
        XCTAssertEqual(layout.cabinetCompartments.map(\.normalizedFrame.height), [0.3, 0.12])
        XCTAssertEqual(layout.cabinetCompartments.map(\.sortOrder), [0, 1])
        XCTAssertEqual(layout.cabinetCompartments.map(\.storageType), [.refrigerated, .refrigerated])
        XCTAssertEqual(layout.doorCompartments.first?.type, .doorShelf)
        XCTAssertEqual(layout.doorCompartments.first?.storageType, .unspecified)
    }

    func testNewLayoutsEncodeAsV2WithStorageType() throws {
        let json = String(decoding: try StoredLayout.encode(FridgeFactory.makeDefault()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"version\":2"))
        XCTAssertTrue(json.contains("\"storageType\":\"refrigerated\""))
        XCTAssertTrue(json.contains("\"type\":\"doorShelf\""))
        XCTAssertFalse(json.contains("doorRack"))
    }

    func testStoreLoadsLegacyRecordWithoutOverwritingIt() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridgeID = UUID()
        let seedContext = ModelContext(container)
        seedContext.insert(FridgeRecord(id: fridgeID, name: "我的冰箱", templateID: FridgeTemplate.standardSingleDoor.id,
                                        lastDoorStateRaw: DoorState.open.rawValue, layoutData: legacyJSON))
        try seedContext.save()

        let fridge = try SwiftDataFridgeStore(container: container).loadOrCreateFridge()
        XCTAssertEqual(fridge.id, fridgeID)
        XCTAssertEqual(fridge.lastDoorState, .open)
        XCTAssertEqual(fridge.cabinetCompartments.map(\.id), [shelfID, drawerID])
        XCTAssertEqual(fridge.cabinetCompartments[1].normalizedFrame.height, 0.12, "legacy sizes are preserved")
        XCTAssertEqual(fridge.doorCompartments.map(\.id), [rackID])
        XCTAssertEqual(FridgeLayoutEngine.validate(fridge), [], "legacy layout below the new UX minimum stays valid")

        // Loading alone must not rewrite the stored bytes.
        let record = try ModelContext(container).fetch(FetchDescriptor<FridgeRecord>()).first
        XCTAssertEqual(record?.layoutData, legacyJSON)
    }

    func testLegacySmallCompartmentCanGrowButNotShrink() throws {
        let layout = try StoredLayout.decode(legacyJSON)
        let fridge = Fridge(id: UUID(), name: "x", templateID: FridgeTemplate.standardSingleDoor.id, lastDoorState: .closed,
                            cabinetCompartments: layout.cabinetCompartments, doorCompartments: layout.doorCompartments)
        let editor = FridgeLayoutEditor(fridge: fridge)
        XCTAssertThrowsError(try editor.resize(drawerID, by: -FridgeLayoutEditor.heightStep))
        try editor.resize(drawerID, by: FridgeLayoutEditor.heightStep)
        XCTAssertEqual(editor.compartment(id: drawerID)!.normalizedFrame.height, 0.14, accuracy: 1e-9)
    }

    func testLegacyLayoutSavedAgainPersistsStorageEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.store")

        let container = try SwiftDataFridgeStore.makeContainer(url: url)
        let context = ModelContext(container)
        context.insert(FridgeRecord(id: UUID(), name: "我的冰箱", templateID: FridgeTemplate.standardSingleDoor.id,
                                    lastDoorStateRaw: DoorState.closed.rawValue, layoutData: legacyJSON))
        try context.save()

        let store = SwiftDataFridgeStore(container: container)
        let editor = FridgeLayoutEditor(fridge: try store.loadOrCreateFridge())
        try editor.setStorageType(drawerID, to: .frozen)
        try store.saveLayout(editor.commit())

        let relaunched = try SwiftDataFridgeStore(container: SwiftDataFridgeStore.makeContainer(url: url)).loadOrCreateFridge()
        XCTAssertEqual(relaunched.cabinetCompartments.map(\.storageType), [.refrigerated, .frozen])
        XCTAssertEqual(relaunched.cabinetCompartments.map(\.id), [shelfID, drawerID])
    }
}
