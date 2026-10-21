import UIKit
import XCTest
@testable import FoodManager

/// Scrollable food icons inside compartments: one icon per record, fixed count badge, horizontal-only
/// scrolling clipped to the compartment, and tap/swipe/edit-mode touch routing.
final class CompartmentIconScrollTests: XCTestCase {
    private var windows: [UIWindow] = [] // keep hosts alive for the duration of a test
    private let shelf = Compartment(id: UUID(), parentZoneID: .cabinet, name: "上層", type: .shelf, storageType: .refrigerated,
                                    sortOrder: 0, normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.22))
    private let doorShelf = Compartment(id: UUID(), parentZoneID: .door, name: "門架 1", type: .doorShelf,
                                        storageType: .unspecified, sortOrder: 0,
                                        normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.28))

    private func summary(_ count: Int, category: (Int) -> String = { _ in "other" }) -> CompartmentContentSummary {
        CompartmentContentSummary(icons: (0..<count).map { FoodIconEntry(foodID: UUID(), categoryID: category($0)) })
    }

    /// Builds a laid-out view (in a window so UICollectionView computes its content size).
    private func makeView(_ compartment: Compartment, items: Int, size: CGSize = CGSize(width: 150, height: 60),
                          category: (Int) -> String = { _ in "other" }) -> CompartmentView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let view = CompartmentView(compartment: compartment)
        view.frame = CGRect(origin: CGPoint(x: 10, y: 10), size: size)
        window.addSubview(view)
        windows.append(window)
        view.apply(compartment, summary: summary(items, category: category))
        layout(view)
        return view
    }

    private func layout(_ view: CompartmentView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.iconCollection.layoutIfNeeded()
    }

    private func center(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // 1: zero items
    func testEmptyCompartmentShowsNoIconsAndZeroCount() {
        let view = makeView(shelf, items: 0)
        XCTAssertEqual(view.countLabel.text, "0")
        XCTAssertTrue(view.iconCollection.isHidden, "no placeholder circles for empty compartments")
        XCTAssertEqual(view.iconCollection.numberOfItems(inSection: 0), 0)
    }

    // 2, 3, 4, 5: one, three, ten, many — every record gets an entry, no maximum
    func testEveryRecordGetsAnIconEntryWithoutLimit() {
        for count in [1, 3, 10, 120] {
            let view = makeView(shelf, items: count)
            XCTAssertEqual(view.iconCollection.numberOfItems(inSection: 0), count)
            XCTAssertEqual(view.countLabel.text, "\(count)")
            XCTAssertFalse(view.iconCollection.isHidden)
        }
    }

    func testFewIconsDoNotScrollManyIconsDo() {
        XCTAssertFalse(makeView(shelf, items: 3).isIconRowScrollable)
        let many = makeView(shelf, items: 10)
        XCTAssertTrue(many.isIconRowScrollable)
        let metrics = CompartmentIconMetrics(bounds: many.bounds)!
        XCTAssertEqual(many.iconCollection.contentSize.width, metrics.contentWidth(count: 10), accuracy: 1,
                       "icons keep their size (not shrunk to fit) and scroll instead")
    }

    // 6: shared category, separate entries
    func testRecordsSharingACategoryAreSeparateEntries() {
        let view = makeView(shelf, items: 4) { $0 < 2 ? "leafy-greens" : "dairy" }
        XCTAssertEqual(view.iconCollection.numberOfItems(inSection: 0), 4)
        XCTAssertEqual(view.summary.icons.filter { $0.categoryID == "leafy-greens" }.count, 2)
    }

    // 7: horizontal only
    func testScrollingIsHorizontalOnly() {
        let view = makeView(shelf, items: 30)
        let collection = view.iconCollection
        XCTAssertEqual((collection.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection, .horizontal)
        XCTAssertEqual(collection.contentSize.height, collection.bounds.height, accuracy: 0.5, "no vertical overflow")
        XCTAssertFalse(collection.alwaysBounceVertical)
        XCTAssertFalse(collection.showsHorizontalScrollIndicator)
        XCTAssertTrue(collection.isScrollEnabled)
        let maxOffset = collection.contentSize.width - collection.bounds.width
        collection.setContentOffset(CGPoint(x: maxOffset, y: 0), animated: false)
        XCTAssertEqual(collection.contentOffset.x, maxOffset, accuracy: 0.5)
    }

    // 8: badge stays put while scrolling
    func testCountBadgeIsFixedWhileIconsScroll() {
        let view = makeView(shelf, items: 30)
        let before = view.countLabel.frame
        view.iconCollection.setContentOffset(CGPoint(x: 200, y: 0), animated: false)
        layout(view)
        XCTAssertEqual(view.countLabel.frame, before)
        XCTAssertFalse(view.countLabel.isDescendant(of: view.iconCollection))
        XCTAssertEqual(before.maxX, view.bounds.maxX - 5, accuracy: 0.5, "top-right corner")
        XCTAssertLessThanOrEqual(before.maxY, view.iconCollection.frame.minY, "badge never overlaps the icon row")
    }

    // 9: clipping inside the compartment
    func testIconRowIsClippedInsideCompartmentAndBelowNameRow() {
        let view = makeView(shelf, items: 50)
        let row = view.iconCollection.frame
        XCTAssertTrue(view.bounds.contains(row))
        XCTAssertTrue(view.iconCollection.clipsToBounds)
        XCTAssertGreaterThanOrEqual(row.minY, CompartmentIconMetrics.topReserve)
    }

    // 10: resizing adapts icon size; too small hides icons instead of clipping them
    func testIconSizeFollowsCompartmentHeight() {
        let view = makeView(shelf, items: 5, size: CGSize(width: 150, height: 70))
        let tall = CompartmentIconMetrics(bounds: view.bounds)!.iconSize
        view.frame.size.height = 44
        layout(view)
        let short = CompartmentIconMetrics(bounds: view.bounds)!.iconSize
        XCTAssertLessThan(short, tall)
        XCTAssertEqual(view.iconCollection.frame.height, short)
        XCTAssertLessThanOrEqual(tall, CompartmentIconMetrics.maxIconSize)

        view.frame.size.height = 30
        layout(view)
        XCTAssertNil(CompartmentIconMetrics(bounds: view.bounds))
        XCTAssertTrue(view.iconCollection.isHidden, "name and count win when there is no room for icons")
    }

    // 11: door compartments scroll independently
    func testDoorCompartmentScrollsIndependently() {
        let door = makeView(doorShelf, items: 20)
        let cabinet = makeView(shelf, items: 20)
        door.iconCollection.setContentOffset(CGPoint(x: 120, y: 0), animated: false)
        XCTAssertTrue(door.isIconRowScrollable)
        XCTAssertEqual(cabinet.iconCollection.contentOffset.x, 0)
    }

    // 12: tap vs swipe routing
    func testTouchRoutingSeparatesSwipeFromTap() {
        let view = makeView(shelf, items: 20)
        let rowCenter = center(of: view.iconCollection.frame)
        XCTAssertTrue(view.hitTest(rowCenter, with: nil) === view.iconCollection, "swipes on a scrollable row scroll it")
        let nameArea = CGPoint(x: 20, y: 10)
        XCTAssertTrue(view.hitTest(nameArea, with: nil) is UIButton, "taps outside the row hit the compartment button")
        // The row's tap recognizer still opens the food list; a pan (swipe) makes it fail instead.
        let taps = view.iconCollection.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        XCTAssertFalse(taps.isEmpty)
        XCTAssertEqual(view.iconCollection.allowsSelection, false)

        var tapped: UUID?
        view.onTap = { tapped = $0 }
        (view.hitTest(nameArea, with: nil) as? UIButton)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(tapped, shelf.id)
    }

    func testNonScrollableRowLeavesWholeCompartmentTappable() {
        let view = makeView(shelf, items: 2)
        XCTAssertTrue(view.hitTest(center(of: view.iconCollection.frame), with: nil) is UIButton)
    }

    // 13: edit mode
    func testEditModeDisablesScrollingAndRoutesToLayoutSelection() {
        let view = makeView(shelf, items: 20)
        view.setEditing(true, selected: false)
        XCTAssertFalse(view.iconCollection.isScrollEnabled)
        XCTAssertTrue(view.hitTest(center(of: view.iconCollection.frame), with: nil) is UIButton)
        view.setEditing(false, selected: false)
        XCTAssertTrue(view.iconCollection.isScrollEnabled)
    }

    // 14: screen sizes — default compartments show legible icons on every supported width
    func testDefaultCompartmentsShowIconsOnAllIPhoneWidths() {
        let template = FridgeTemplate.standardSingleDoor
        for width: CGFloat in [375, 390, 402, 440] {
            let image = FridgeLayoutEngine.aspectFitRect(
                contentSize: template.openImageSize,
                in: CGRect(x: 0, y: 0, width: width - 2 * Theme.Metric.openFridgeInset, height: 10_000))
            for zone in ZoneID.allCases {
                let zoneFrame = FridgeLayoutEngine.zoneFrame(zone, template: template, imageFrame: image)
                for compartment in FridgeFactory.makeDefault().compartments(in: zone) {
                    let frame = FridgeLayoutEngine.rect(for: compartment.normalizedFrame, in: zoneFrame)
                    let metrics = CompartmentIconMetrics(bounds: CGRect(origin: .zero, size: frame.size))
                    XCTAssertNotNil(metrics, "\(width)pt \(compartment.name)")
                    XCTAssertGreaterThanOrEqual(metrics?.iconSize ?? 0, 20, "\(width)pt \(compartment.name)")
                }
            }
        }
    }

    func testPlaceholderIconsAreCachedPerCategoryAndSize() {
        let a = CategoryIconProvider.image(for: "dairy", size: 24)
        XCTAssertTrue(a === CategoryIconProvider.image(for: "dairy", size: 24))
        XCTAssertFalse(a === CategoryIconProvider.image(for: "eggs", size: 24))
        XCTAssertEqual(FoodCategoryCatalog.all.count, 20)
        XCTAssertEqual(Set(FoodCategoryCatalog.all.map(\.id)).count, 20)
        XCTAssertEqual(FoodCategoryCatalog.category(id: "unknown-id").id, FoodCategoryCatalog.otherID)
    }
}
