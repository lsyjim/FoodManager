import CoreGraphics
import XCTest
@testable import FoodManager

final class FridgeLayoutEngineTests: XCTestCase {
    private let template = FridgeTemplate.standardSingleDoor

    private func compartment(_ zone: ZoneID = .cabinet, type: CompartmentType = .shelf, y: Double, height: Double,
                             name: String = "A", id: UUID = UUID()) -> Compartment {
        // sortOrder follows y so order validation stays satisfied in these geometry tests.
        Compartment(id: id, parentZoneID: zone, name: name, type: type, storageType: zone.defaultStorageType,
                    sortOrder: Int((y * 1000).rounded()),
                    normalizedFrame: NormalizedRect(x: 0, y: y, width: 1, height: height))
    }

    // MARK: Geometry

    func testAspectFitCentersContent() {
        let rect = FridgeLayoutEngine.aspectFitRect(contentSize: CGSize(width: 200, height: 100),
                                                    in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testAspectFitHandlesEmptyInput() {
        XCTAssertEqual(FridgeLayoutEngine.aspectFitRect(contentSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)), .zero)
    }

    func testNormalizedRectMapsIntoContainer() {
        let frame = FridgeLayoutEngine.rect(for: NormalizedRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5),
                                            in: CGRect(x: 10, y: 20, width: 200, height: 400))
        XCTAssertEqual(frame, CGRect(x: 110, y: 120, width: 100, height: 200))
    }

    func testCabinetAndDoorZonesAreIndependentAndDisjoint() {
        let imageFrame = CGRect(x: 0, y: 0, width: 761, height: 654)
        let cabinet = FridgeLayoutEngine.zoneFrame(.cabinet, template: template, imageFrame: imageFrame)
        let door = FridgeLayoutEngine.zoneFrame(.door, template: template, imageFrame: imageFrame)
        XCTAssertFalse(cabinet.intersects(door))
        XCTAssertLessThan(cabinet.maxX, door.minX, "cabinet is left of the right-hinged door")
        XCTAssertTrue(imageFrame.contains(cabinet))
        XCTAssertTrue(imageFrame.contains(door))
        // Measured interior bounds from the artwork (pixels).
        XCTAssertEqual(cabinet.minX, 56, accuracy: 0.5)
        XCTAssertEqual(door.minX, 440, accuracy: 0.5)
    }

    func testZoneFramesScaleWithDisplaySize() {
        let small = FridgeLayoutEngine.zoneFrame(.door, template: template,
                                                 imageFrame: CGRect(x: 0, y: 0, width: 392, height: 338.5))
        let large = FridgeLayoutEngine.zoneFrame(.door, template: template,
                                                 imageFrame: CGRect(x: 0, y: 0, width: 784, height: 677))
        XCTAssertEqual(small.width * 2, large.width, accuracy: 0.001)
        XCTAssertEqual(small.minY * 2, large.minY, accuracy: 0.001)
    }

    // MARK: Packing

    func testPackStacksFromTopWithGapsAndRenumbers() {
        var a = compartment(y: 0.7, height: 0.2, name: "A"); a.sortOrder = 5
        var b = compartment(y: 0.1, height: 0.3, name: "B"); b.sortOrder = 2
        let packed = FridgeLayoutEngine.pack([a, b])
        XCTAssertEqual(packed.map(\.name), ["B", "A"])
        XCTAssertEqual(packed.map(\.sortOrder), [0, 1])
        XCTAssertEqual(packed[0].normalizedFrame.y, 0)
        XCTAssertEqual(packed[1].normalizedFrame.y, 0.3 + FridgeLayoutEngine.gap, accuracy: 1e-9)
        XCTAssertEqual(packed[1].normalizedFrame.height, 0.2)
    }

    func testDefaultFridgeHasThreeShelvesOneDrawerAndThreeDoorRacks() {
        let fridge = FridgeFactory.makeDefault()
        XCTAssertEqual(fridge.cabinetCompartments.filter { $0.type == .shelf }.count, 3)
        XCTAssertEqual(fridge.cabinetCompartments.filter { $0.type == .drawer }.count, 1)
        XCTAssertEqual(fridge.doorCompartments.map(\.type), [.doorShelf, .doorShelf, .doorShelf])
        XCTAssertEqual(fridge.lastDoorState, .closed)
        XCTAssertEqual(FridgeLayoutEngine.validate(fridge), [])
    }

    // MARK: Validation

    func testRejectsOverlap() {
        let a = compartment(y: 0, height: 0.3), b = compartment(y: 0.2, height: 0.3)
        XCTAssertEqual(FridgeLayoutEngine.validate([a, b], in: .cabinet), [.overlap(a.id, b.id)])
    }

    func testTouchingEdgesAreNotOverlap() {
        let a = compartment(y: 0, height: 0.3), b = compartment(y: 0.3, height: 0.3)
        XCTAssertEqual(FridgeLayoutEngine.validate([a, b], in: .cabinet), [])
    }

    func testRejectsOutOfBounds() {
        let a = compartment(y: 0.9, height: 0.2)
        XCTAssertEqual(FridgeLayoutEngine.validate([a], in: .cabinet), [.outOfBounds(a.id)])
        let b = compartment(y: -0.1, height: 0.2)
        XCTAssertEqual(FridgeLayoutEngine.validate([b], in: .cabinet), [.outOfBounds(b.id)])
    }

    func testRejectsTooSmall() {
        let a = compartment(y: 0, height: FridgeLayoutEngine.absoluteMinHeight - 0.01)
        XCTAssertEqual(FridgeLayoutEngine.validate([a], in: .cabinet), [.tooSmall(a.id)])
    }

    func testRejectsBadNamesAndWrongZoneTypes() {
        let blank = compartment(y: 0, height: 0.2, name: "   ")
        XCTAssertEqual(FridgeLayoutEngine.validate([blank], in: .cabinet), [.invalidName(blank.id)])
        let rackInCabinet = compartment(.cabinet, type: .doorShelf, y: 0, height: 0.2)
        XCTAssertEqual(FridgeLayoutEngine.validate([rackInCabinet], in: .cabinet), [.typeNotAllowed(rackInCabinet.id)])
        let doorItemInCabinet = compartment(.door, type: .doorShelf, y: 0, height: 0.2)
        XCTAssertTrue(FridgeLayoutEngine.validate([doorItemInCabinet], in: .cabinet).contains(.wrongZone(doorItemInCabinet.id)))
    }

    func testRejectsDuplicateIDsAcrossZones() {
        let id = UUID()
        var fridge = FridgeFactory.makeDefault()
        fridge.cabinetCompartments = [compartment(.cabinet, y: 0, height: 0.2, id: id)]
        fridge.doorCompartments = [compartment(.door, type: .doorShelf, y: 0, height: 0.2, id: id)]
        XCTAssertEqual(FridgeLayoutEngine.validate(fridge), [.duplicateID(id)])
    }
}
