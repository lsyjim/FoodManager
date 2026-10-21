import CoreGraphics
import XCTest
@testable import FoodManager

/// 19 & 20: zone geometry and touch targets across portrait iPhone widths (pt).
final class ScreenSizeLayoutTests: XCTestCase {
    private let template = FridgeTemplate.standardSingleDoor
    private let widths: [String: CGFloat] = ["iPhone SE": 375, "iPhone 16e": 390, "iPhone 17": 402, "iPhone 17 Pro Max": 440]

    /// Mirrors FridgeHomeViewController: the open fridge fills the width minus a small inset (height is not limiting).
    private func imageFrame(screenWidth: CGFloat) -> CGRect {
        let width = screenWidth - 2 * Theme.Metric.openFridgeInset
        return FridgeLayoutEngine.aspectFitRect(contentSize: template.openImageSize,
                                                in: CGRect(x: 0, y: 0, width: width, height: 10_000))
    }

    func testSmallestCompartmentTouchTargetIsAtLeast44ptOnEverySupportedWidth() {
        for (device, width) in widths {
            let image = imageFrame(screenWidth: width)
            for zone in ZoneID.allCases {
                let zoneFrame = FridgeLayoutEngine.zoneFrame(zone, template: template, imageFrame: image)
                XCTAssertGreaterThanOrEqual(FridgeLayoutEngine.minimumTouchHeight(zoneHeight: zoneFrame.height),
                                            Theme.Metric.minTouchTarget, "\(device) \(zone)")
            }
        }
    }

    func testZonesStayInsideArtworkAndApartOnEveryWidth() {
        for (device, width) in widths {
            let image = imageFrame(screenWidth: width)
            let cabinet = FridgeLayoutEngine.zoneFrame(.cabinet, template: template, imageFrame: image)
            let door = FridgeLayoutEngine.zoneFrame(.door, template: template, imageFrame: image)
            XCTAssertTrue(image.contains(cabinet), device)
            XCTAssertTrue(image.contains(door), device)
            XCTAssertFalse(cabinet.intersects(door), device)
            XCTAssertEqual(image.width / image.height, template.openImageSize.width / template.openImageSize.height,
                           accuracy: 0.001, "aspect ratio preserved on \(device)")
        }
    }

    func testOpenFridgeFitsAboveCompactEditSheetOnSE() {
        // SE: 667pt tall, 20pt status bar, ~52pt header + ~44pt edit bar + 12pt spacing above the fridge.
        let fridgeTop: CGFloat = 20 + 8 + 44 + 8 + 44 + 12
        let image = imageFrame(screenWidth: 375)
        let cabinet = FridgeLayoutEngine.zoneFrame(.cabinet, template: template, imageFrame: image)
        let sheetTop = 667 - CompartmentEditSheetController.detentHeight
        // The cabinet's lower 3/4 may sit under the sheet edge only marginally; the zone top must stay visible.
        XCTAssertLessThan(fridgeTop + (cabinet.minY - image.minY), sheetTop)
        XCTAssertLessThan(fridgeTop + image.height - sheetTop, 30, "sheet overlaps only the fridge's bottom frame")
    }

    func testHitOutsetsOfNeighboursNeverOverlap() {
        let zoneHeight: CGFloat = 250
        let packed = FridgeLayoutEngine.pack(FridgeFactory.makeDefault().cabinetCompartments)
        let outset = FridgeLayoutEngine.hitOutset(zoneHeight: zoneHeight)
        for (a, b) in zip(packed, packed.dropFirst()) {
            let aBottom = CGFloat(a.normalizedFrame.maxY) * zoneHeight + outset
            let bTop = CGFloat(b.normalizedFrame.y) * zoneHeight - outset
            XCTAssertLessThanOrEqual(aBottom, bTop + 0.0001)
        }
    }
}
