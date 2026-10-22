import ImageIO
import PhotosUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import FoodManager

/// Magnet store whose writes can be made to fail.
final class FailingMagnetStore: MagnetStore {
    struct Failure: Error {}
    let base: MagnetStore
    var failWrites = false
    init(base: MagnetStore) { self.base = base }
    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] { try base.magnets(fridgeID: fridgeID) }
    func allMagnets() throws -> [FridgeMagnet] { try base.allMagnets() }
    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID, newImages: [UUID: Data]) throws {
        if failWrites { throw Failure() }
        try base.replaceMagnets(magnets, fridgeID: fridgeID, newImages: newImages)
    }
    func imageData(id: UUID) throws -> Data? { try base.imageData(id: id) }
    func storedImageIDs() throws -> Set<UUID> { try base.storedImageIDs() }
    func addImages(_ images: [UUID: Data]) throws {
        if failWrites { throw Failure() }
        try base.addImages(images)
    }
}

/// Phase 4.3: fridge magnets — geometry, draft editing, storage, images, fridges, backup and UI wiring.
final class MagnetTests: XCTestCase {
    private var container: ModelContainer!
    private var directory: FridgeDirectory!
    private var selection: InMemoryFridgeSelectionStore!
    private var workDirectory: URL!
    private var images: MagnetImageStore!
    private var store: FailingMagnetStore!
    private var library: MagnetLibrary!
    private let template = FridgeTemplate.standardSingleDoor

    override func setUpWithError() throws {
        container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        selection = InMemoryFridgeSelectionStore()
        directory = try FridgeDirectory(fridgeStore: SwiftDataFridgeStore(container: container),
                                        foodStore: SwiftDataFoodStore(container: container), selection: selection)
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MagnetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        images = MagnetImageStore(directory: workDirectory.appendingPathComponent("Magnets"))
        store = FailingMagnetStore(base: SwiftDataMagnetStore(container: container))
        library = MagnetLibrary(store: store, images: images)
        directory.onFridgeDeleted = { [unowned self] in self.library.removeUnreferencedImages() }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private var fridge: Fridge { directory.fridges[0] }

    /// A test image encoded as PNG (with alpha) or JPEG, optionally with an EXIF orientation.
    private func imageData(width: Int, height: Int, alpha: Bool = false, orientation: Int? = nil) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !alpha
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            if !alpha {
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
            }
        }
        let data = NSMutableData()
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        let destination = CGImageDestinationCreateWithData(data, type, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image.cgImage!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func photoDraft(_ fridgeID: UUID) throws -> (MagnetDraft, ImportedMagnetImage) {
        let imported = try images.importImage(data: imageData(width: 300, height: 200))
        var draft = MagnetDraft(fridgeID: fridgeID, magnets: try library.magnets(fridgeID: fridgeID))
        draft.add(source: .photo, localImageID: imported.id, size: (0.4, 0.3))
        return (draft, imported)
    }

    private func builtIn(_ draft: inout MagnetDraft, _ id: String = "daisy") -> FridgeMagnet {
        draft.add(source: .builtIn, builtInAssetID: id, size: (0.3, 0.2))!
    }

    // 1
    func testPositionNormalizationRoundTrips() {
        let door = CGRect(x: 20, y: 10, width: 200, height: 400)
        let point = CGPoint(x: 70, y: 310)
        let normalized = MagnetGeometry.normalizedPoint(point, in: door)!
        XCTAssertEqual(normalized.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(normalized.y, 0.75, accuracy: 1e-9)
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.setCenter(magnet.id, x: normalized.x, y: normalized.y)
        XCTAssertEqual(MagnetGeometry.center(of: draft.magnet(magnet.id)!, in: door), point)
        XCTAssertNil(MagnetGeometry.normalizedPoint(point, in: .zero))
    }

    // 2
    func testSameArrangementOnDifferentScreenSizes() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        // iPhone SE-like and Pro Max-like fridge boxes.
        for bounds in [CGRect(x: 0, y: 0, width: 170, height: 313), CGRect(x: 0, y: 0, width: 240, height: 442)] {
            let door = MagnetGeometry.doorRect(template: template, in: bounds)
            let center = MagnetGeometry.center(of: magnet, in: door)
            let size = MagnetGeometry.size(of: magnet, in: door)
            XCTAssertEqual(Double((center.x - door.minX) / door.width), magnet.centerX, accuracy: 1e-9)
            XCTAssertEqual(Double((center.y - door.minY) / door.height), magnet.centerY, accuracy: 1e-9)
            XCTAssertEqual(Double(size.width / door.width), magnet.width, accuracy: 1e-9)
        }
    }

    // 3
    func testAspectFitAndDoorRectIgnoreArtworkPadding() {
        // Bounds wider than the artwork: the art is centered with empty space left and right.
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 650)
        let art = MagnetGeometry.aspectFitRect(content: template.closedImageSize, in: bounds)
        XCTAssertEqual(art.height, 650, accuracy: 0.001)
        XCTAssertEqual(art.width, 353, accuracy: 0.001)
        XCTAssertEqual(art.minX, (600 - 353) / 2, accuracy: 0.001)
        let door = MagnetGeometry.doorRect(template: template, in: bounds)
        XCTAssertEqual(door.minX, art.minX + 24, accuracy: 0.001)
        XCTAssertEqual(door.minY, 8, accuracy: 0.001)
        XCTAssertEqual(door.width, 322, accuracy: 0.001)
        XCTAssertEqual(door.height, 622, accuracy: 0.001)
        XCTAssertEqual(MagnetGeometry.aspectFitRect(content: .zero, in: bounds), .zero)
        XCTAssertEqual(template.closedDoorAspect, 322.0 / 622, accuracy: 1e-9)
    }

    // 4, 7
    func testDraggingStaysOnTheDoor() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.setCenter(magnet.id, x: 0.5, y: 0.5)
        draft.move(magnet.id, dx: 0.1, dy: -0.2)
        XCTAssertEqual(draft.magnet(magnet.id)!.centerX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(draft.magnet(magnet.id)!.centerY, 0.3, accuracy: 1e-9)
        draft.move(magnet.id, dx: 5, dy: -5)
        XCTAssertEqual(draft.magnet(magnet.id)!.centerX, 1)
        XCTAssertEqual(draft.magnet(magnet.id)!.centerY, 0)
        draft.move(magnet.id, dx: .nan, dy: .infinity)
        XCTAssertTrue(MagnetGeometry.isValid(draft.magnet(magnet.id)!), "non-finite input never produces invalid values")
        let broken = FridgeMagnet(id: UUID(), fridgeID: fridge.id, source: .builtIn, builtInAssetID: "daisy", localImageID: nil,
                                  centerX: .nan, centerY: 7, width: .infinity, height: -1, rotation: 10,
                                  zIndex: 0, createdAt: .now, updatedAt: .now)
        XCTAssertFalse(MagnetGeometry.isValid(broken))
        XCTAssertTrue(MagnetGeometry.isValid(MagnetGeometry.sanitized(broken)))
    }

    // 5
    func testRotationWrapsAround() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.rotate(magnet.id, by: .pi / 4)
        XCTAssertEqual(draft.magnet(magnet.id)!.rotation, .pi / 4, accuracy: 1e-9)
        draft.rotate(magnet.id, by: 2 * .pi)
        XCTAssertEqual(draft.magnet(magnet.id)!.rotation, .pi / 4, accuracy: 1e-9)
        draft.rotate(magnet.id, by: .pi)
        XCTAssertEqual(draft.magnet(magnet.id)!.rotation, -3 * .pi / 4, accuracy: 1e-9)
        draft.rotate(magnet.id, by: .nan)
        XCTAssertEqual(draft.magnet(magnet.id)!.rotation, -3 * .pi / 4, accuracy: 1e-9)
    }

    // 6
    func testScalingKeepsAspectRatioWithinLimits() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        let ratio = magnet.height / magnet.width
        draft.scale(magnet.id, by: 100)
        XCTAssertEqual(draft.magnet(magnet.id)!.width, MagnetGeometry.maxWidth, accuracy: 1e-9)
        XCTAssertEqual(draft.magnet(magnet.id)!.height / draft.magnet(magnet.id)!.width, ratio, accuracy: 1e-9)
        draft.scale(magnet.id, by: 0.001)
        XCTAssertEqual(draft.magnet(magnet.id)!.width, MagnetGeometry.minWidth, accuracy: 1e-9)
        draft.scale(magnet.id, by: -3)
        XCTAssertEqual(draft.magnet(magnet.id)!.width, MagnetGeometry.minWidth, accuracy: 1e-9, "invalid factors are ignored")
        let size = MagnetGeometry.initialSize(imageSize: CGSize(width: 200, height: 100), doorAspect: 0.5, width: 0.4)
        XCTAssertEqual(size.height, 0.4 * 0.5 * 0.5, accuracy: 1e-9, "a 2:1 photo stays 2:1 on the door")
    }

    // 8
    func testLayerOrdering() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let a = builtIn(&draft, "daisy"), b = builtIn(&draft, "pomeranian"), c = builtIn(&draft, "postcard-park")
        XCTAssertEqual(draft.magnets.map(\.id), [a.id, b.id, c.id])
        draft.bringForward(a.id)
        XCTAssertEqual(draft.magnets.map(\.id), [b.id, a.id, c.id])
        draft.sendBackward(c.id)
        XCTAssertEqual(draft.magnets.map(\.id), [b.id, c.id, a.id])
        draft.sendBackward(b.id) // already at the bottom
        XCTAssertEqual(draft.magnets.map(\.zIndex), [0, 1, 2])
    }

    // 9
    func testDuplicationSharesTheImage() throws {
        var (draft, imported) = try photoDraft(fridge.id)
        let original = draft.magnets[0]
        let copy = try XCTUnwrap(draft.duplicate(original.id))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.localImageID, imported.id)
        XCTAssertEqual(copy.width, original.width)
        XCTAssertEqual(draft.magnets.last?.id, copy.id, "copy goes on top")
        XCTAssertEqual(images.storedImageIDs(), [imported.id], "no duplicated bytes")
    }

    // 10
    func testDeletionRenumbersLayers() {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let a = builtIn(&draft), b = builtIn(&draft), c = builtIn(&draft)
        draft.delete(b.id)
        XCTAssertEqual(draft.magnets.map(\.id), [a.id, c.id])
        XCTAssertEqual(draft.magnets.map(\.zIndex), [0, 1])
    }

    // 11
    func testSavePersistsTheDraft() throws {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.rotate(magnet.id, by: 0.3)
        try library.commit(draft)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id), draft.magnets)
        var next = MagnetDraft(fridgeID: fridge.id, magnets: try library.magnets(fridgeID: fridge.id))
        XCTAssertFalse(next.hasChanges)
        next.move(magnet.id, dx: 0.1, dy: 0)
        XCTAssertTrue(next.hasChanges)
    }

    // 12
    func testCancelRestoresTheArrangementAndDropsImportedImages() throws {
        var saved = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&saved)
        try library.commit(saved)
        let before = try library.magnets(fridgeID: fridge.id)

        var (draft, imported) = try photoDraft(fridge.id)
        draft.move(magnet.id, dx: 0.2, dy: 0.2)
        draft.scale(magnet.id, by: 1.5)
        draft.bringForward(magnet.id)
        library.discard(draft)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id), before, "storage never saw the draft")
        XCTAssertFalse(images.exists(imported.id), "uncommitted photo removed")
        XCTAssertEqual(MagnetDraft(fridgeID: fridge.id, magnets: before).magnets, before)
    }

    // 13
    func testPersistenceFailureKeepsDraftAndFiles() throws {
        var (draft, imported) = try photoDraft(fridge.id)
        store.failWrites = true
        XCTAssertThrowsError(try library.commit(draft))
        XCTAssertTrue(images.exists(imported.id), "nothing is cleaned up after a failed save")
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id), [])
        XCTAssertEqual(draft.magnets.count, 1)
        store.failWrites = false
        try library.commit(draft) // retry
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id), draft.magnets)
        XCTAssertTrue(images.exists(imported.id))
        draft.delete(draft.magnets[0].id)
    }

    // 14
    @MainActor
    func testImportCancellationChangesNothing() {
        let editor = MagnetEditorViewController(fridge: fridge, library: library, magnets: [])
        editor.loadViewIfNeeded()
        editor.picker(PHPickerViewController(configuration: PHPickerConfiguration()), didFinishPicking: [])
        XCTAssertTrue(editor.currentDraft.magnets.isEmpty)
        XCTAssertFalse(editor.currentDraft.hasChanges)
        XCTAssertTrue(images.storedImageIDs().isEmpty)
    }

    // 15
    func testLargeImagesAreDownsampledWithOrientationAndTransparency() throws {
        let large = try images.importImage(data: imageData(width: 4000, height: 3000))
        XCTAssertEqual(large.pixelSize, CGSize(width: 1024, height: 768))
        XCTAssertEqual(images.pixelSize(large.id), CGSize(width: 1024, height: 768))
        XCTAssertLessThanOrEqual(max(images.thumbnail(large.id)!.size.width, images.thumbnail(large.id)!.size.height), 240)

        // EXIF orientation 6 (rotated 90°): stored upright, so a 400×200 landscape file becomes 200×400.
        let rotated = try images.importImage(data: imageData(width: 400, height: 200, orientation: 6))
        XCTAssertEqual(rotated.pixelSize, CGSize(width: 200, height: 400))

        let transparent = try images.importImage(data: imageData(width: 300, height: 300, alpha: true))
        let stored = try XCTUnwrap(images.data(transparent.id))
        XCTAssertEqual(stored.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "images with alpha stay PNG")
        let opaqueBytes = try XCTUnwrap(images.data(large.id))
        XCTAssertEqual(opaqueBytes.prefix(2), Data([0xFF, 0xD8]), "opaque photos are stored as JPEG")

        XCTAssertThrowsError(try images.importImage(data: Data("not an image".utf8))) {
            XCTAssertEqual($0 as? MagnetImageError, .unsupported)
        }
        XCTAssertThrowsError(try images.importImage(at: workDirectory.appendingPathComponent("missing.jpg")))
        XCTAssertNotNil(images.image(large.id))
    }

    // 16
    func testImageFilesAreCleanedUpAfterCommit() throws {
        let (draft, imported) = try photoDraft(fridge.id)
        try library.commit(draft)
        let orphan = try images.importImage(data: imageData(width: 50, height: 50))
        var next = MagnetDraft(fridgeID: fridge.id, magnets: try library.magnets(fridgeID: fridge.id))
        next.delete(next.magnets[0].id)
        try library.commit(next)
        XCTAssertFalse(images.exists(imported.id))
        XCTAssertFalse(images.exists(orphan.id), "files no magnet uses are removed after a successful save")
    }

    // 17
    func testSharedImageSurvivesUntilLastReferenceIsGone() throws {
        var (draft, imported) = try photoDraft(fridge.id)
        let copy = try XCTUnwrap(draft.duplicate(draft.magnets[0].id))
        try library.commit(draft)
        var next = MagnetDraft(fridgeID: fridge.id, magnets: try library.magnets(fridgeID: fridge.id))
        next.delete(copy.id)
        try library.commit(next)
        XCTAssertTrue(images.exists(imported.id), "still used by the original")
        next.delete(next.magnets[0].id)
        try library.commit(next)
        XCTAssertFalse(images.exists(imported.id))
    }

    // 18
    func testFridgesKeepTheirOwnMagnets() throws {
        let second = try directory.create(name: "儲藏室")
        var a = MagnetDraft(fridgeID: fridge.id, magnets: [])
        _ = builtIn(&a, "daisy")
        try library.commit(a)
        var b = MagnetDraft(fridgeID: second.id, magnets: [])
        _ = builtIn(&b, "pomeranian")
        _ = builtIn(&b, "postcard-park")
        try library.commit(b)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id).map(\.builtInAssetID), ["daisy"])
        XCTAssertEqual(try library.magnets(fridgeID: second.id).map(\.builtInAssetID), ["pomeranian", "postcard-park"])
        try library.commit(MagnetDraft(fridgeID: second.id, magnets: [])) // clearing B
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id).count, 1, "A untouched")
        XCTAssertEqual(try store.allMagnets().count, 1)
    }

    // 19
    func testDeletingAFridgeRemovesItsMagnetsAndUnusedPhotos() throws {
        let second = try directory.create(name: "儲藏室")
        let (draftB, onlyB) = try photoDraft(second.id)
        try library.commit(draftB)
        // A photo shared by both fridges must survive.
        let shared = try images.importImage(data: imageData(width: 80, height: 80))
        var a = MagnetDraft(fridgeID: fridge.id, magnets: [])
        a.add(source: .photo, localImageID: shared.id, size: (0.3, 0.3))
        try library.commit(a)
        var b = MagnetDraft(fridgeID: second.id, magnets: try library.magnets(fridgeID: second.id))
        b.add(source: .photo, localImageID: shared.id, size: (0.3, 0.3))
        try library.commit(b)

        try directory.delete(second.id)
        XCTAssertEqual(try library.magnets(fridgeID: second.id), [])
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id).count, 1)
        XCTAssertFalse(images.exists(onlyB.id))
        XCTAssertTrue(images.exists(shared.id))
    }

    // 20
    func testLegacyStoreWithoutMagnetsOpens() throws {
        let url = workDirectory.appendingPathComponent("legacy.store")
        let fridgeID: UUID
        do {
            let legacySchema = Schema([FridgeRecord.self, FoodItemRecord.self])
            let legacy = try ModelContainer(for: legacySchema, configurations: [ModelConfiguration(schema: legacySchema, url: url)])
            let context = ModelContext(legacy)
            let old = FridgeFactory.makeDefault()
            fridgeID = old.id
            context.insert(FridgeRecord(id: old.id, name: old.name, templateID: old.templateID, lastDoorStateRaw: "closed",
                                        layoutData: try StoredLayout.encode(old)))
            try context.save()
        }
        let upgraded = try SwiftDataFridgeStore.makeContainer(url: url)
        XCTAssertEqual(try SwiftDataFridgeStore(container: upgraded).loadAll().map(\.fridge.id), [fridgeID])
        XCTAssertEqual(try SwiftDataMagnetStore(container: upgraded).magnets(fridgeID: fridgeID), [])
    }

    // 21, 22
    func testBackupCarriesMagnetsAndPhotoBytes() throws {
        let suite = "MagnetBackup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func service(_ container: ModelContainer, _ images: MagnetImageStore) -> BackupService {
            BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                          preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection),
                          magnetImages: images, recoveryDirectory: nil, applicationVersion: "test")
        }
        var (draft, imported) = try photoDraft(fridge.id)
        _ = draft.duplicate(draft.magnets[0].id)
        _ = builtIn(&draft, "pomeranian")
        try library.commit(draft)
        let backup = try service(container, images).makeBackup()
        XCTAssertEqual(backup.formatVersion, 2)
        XCTAssertEqual(backup.allMagnets.count, 3)
        XCTAssertEqual(backup.allMagnetImages.map(\.id), [imported.id], "one image for two magnets")
        XCTAssertEqual(backup.allMagnetImages.first?.data, images.data(imported.id))

        // Restore into a fresh install (new database, empty image folder).
        let freshContainer = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let freshImages = MagnetImageStore(directory: workDirectory.appendingPathComponent("Fresh"))
        let decoded = try BackupValidator.decode(BackupCoding.encoder().encode(backup))
        try service(freshContainer, freshImages).restore(decoded)
        XCTAssertEqual(try SwiftDataMagnetStore(container: freshContainer).magnets(fridgeID: fridge.id), draft.magnets)
        XCTAssertEqual(freshImages.data(imported.id), images.data(imported.id), "identical bytes after restore")
        XCTAssertNotNil(freshImages.thumbnail(imported.id))

        // Without the local file, the synced image record still provides the bytes.
        let bytes = images.data(imported.id)
        images.remove(imported.id)
        XCTAssertEqual(try service(container, images).makeBackup().allMagnetImages.first?.data, bytes)
        // With neither, export never silently drops the photo: it asks first (allowMissingPhotos).
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<MagnetImageRecord>()) { context.delete(record) }
        try context.save()
        XCTAssertThrowsError(try service(container, images).makeBackup()) { XCTAssertEqual($0 as? BackupError, .magnetImageMissing) }
        let partial = try service(container, images).makeBackup(allowMissingPhotos: true)
        XCTAssertEqual(BackupValidator.summary(of: partial).missingPhotoCount, 2, "both magnets that show the photo")
        XCTAssertNoThrow(try BackupValidator.decode(BackupCoding.encoder().encode(partial)))
    }

    func testVersionOneBackupWithoutMagnetsStillImports() throws {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        _ = builtIn(&draft)
        try library.commit(draft)
        let suite = "MagnetV1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                                    preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection),
                                    magnetImages: images, recoveryDirectory: nil, applicationVersion: "test")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BackupCoding.encoder().encode(service.makeBackup())) as? [String: Any])
        json["formatVersion"] = 1
        json["magnets"] = nil
        json["magnetImages"] = nil
        let v1 = try BackupValidator.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(v1.magnets)
        try service.restore(v1)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id), [], "full replacement: a v1 backup has no magnets")

        var bad = try service.makeBackup()
        bad.magnets = [FridgeMagnet(id: UUID(), fridgeID: UUID(), source: .builtIn, builtInAssetID: "daisy", localImageID: nil,
                                    centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, rotation: 0, zIndex: 0,
                                    createdAt: .now, updatedAt: .now)]
        XCTAssertThrowsError(try BackupValidator.validate(bad)) { XCTAssertEqual($0 as? BackupError, .invalidMagnets) }
        bad.magnets![0].fridgeID = fridge.id
        bad.magnets![0].source = .photo
        bad.magnets![0].localImageID = UUID()
        // A photo magnet without its bytes (exported while the photo was still downloading, with consent) is
        // valid: it restores as a blank card in the same place, and the preview says so.
        XCTAssertNoThrow(try BackupValidator.validate(bad))
        XCTAssertEqual(BackupValidator.summary(of: bad).missingPhotoCount, 1)
        bad.magnets![0].localImageID = nil
        XCTAssertThrowsError(try BackupValidator.validate(bad), "a photo magnet needs an image ID")
    }

    // 23
    @MainActor
    func testEditGesturesDoNotConflict() throws {
        let board = MagnetBoardView(template: template, library: library)
        board.frame = CGRect(x: 0, y: 0, width: 200, height: 368)
        XCTAssertFalse(board.isUserInteractionEnabled, "display mode never takes touches")
        XCTAssertTrue((board.gestureRecognizers ?? []).isEmpty)
        board.setMode(.edit)
        let gestures = try XCTUnwrap(board.gestureRecognizers)
        XCTAssertEqual(gestures.count, 4)
        let tap = try XCTUnwrap(gestures.first { $0 is UITapGestureRecognizer })
        let pan = try XCTUnwrap(gestures.first { $0 is UIPanGestureRecognizer })
        let pinch = try XCTUnwrap(gestures.first { $0 is UIPinchGestureRecognizer })
        let rotation = try XCTUnwrap(gestures.first { $0 is UIRotationGestureRecognizer })
        XCTAssertTrue(board.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: rotation))
        XCTAssertTrue(board.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: pinch))
        XCTAssertFalse(board.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: pan))
        XCTAssertFalse(board.gestureRecognizerShouldBegin(pan), "no drag on an empty door without a selection")
        XCTAssertTrue(board.gestureRecognizer(pan, shouldReceive: UITouch()))

        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.rotate(magnet.id, by: .pi / 4)
        board.render(draft.magnets)
        board.layoutIfNeeded()
        let center = MagnetGeometry.center(of: draft.magnet(magnet.id)!, in: board.doorRect)
        XCTAssertEqual(board.magnetID(at: center), magnet.id)
        XCTAssertNil(board.magnetID(at: CGPoint(x: 2, y: 2)))
        board.setMode(.display)
        XCTAssertTrue((board.gestureRecognizers ?? []).isEmpty)
        XCTAssertNil(board.selectedID)
    }

    // 24
    @MainActor
    func testMagnetsDoNotBlockOpeningTheDoor() throws {
        let session = try AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting, selection: selection).get()
        var draft = MagnetDraft(fridgeID: session.loadResult.fridge.id, magnets: [])
        let magnet = draft.add(source: .builtIn, builtInAssetID: "daisy", size: (0.9, 0.9))!
        try session.magnets.commit(draft)
        let home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = home
        window.makeKeyAndVisible()
        home.view.layoutIfNeeded()
        let board = try XCTUnwrap(home.view.allSubviews.compactMap { $0 as? MagnetBoardView }.first)
        XCTAssertEqual(board.magnets.map(\.id), [magnet.id])
        XCTAssertFalse(board.isUserInteractionEnabled)
        let point = board.convert(MagnetGeometry.center(of: magnet, in: board.doorRect), to: home.view)
        let hit = try XCTUnwrap(home.view.hitTest(point, with: nil))
        XCTAssertTrue(hit is ClosedFridgeButton || hit.superview is ClosedFridgeButton, "a tap on a magnet still opens the door")
        XCTAssertTrue(home.view.allSubviews.contains { $0.accessibilityIdentifier == "home.decorate" })
        window.isHidden = true
    }

    // 25
    func testMagnetsSurviveRelaunch() throws {
        let url = workDirectory.appendingPathComponent("disk.store")
        let fridgeID: UUID
        let saved: [FridgeMagnet]
        do {
            let disk = try SwiftDataFridgeStore.makeContainer(url: url)
            fridgeID = try SwiftDataFridgeStore(container: disk).load().fridge.id
            let diskLibrary = MagnetLibrary(store: SwiftDataMagnetStore(container: disk), images: images)
            var draft = MagnetDraft(fridgeID: fridgeID, magnets: [])
            let photo = try images.importImage(data: imageData(width: 120, height: 90))
            draft.add(source: .photo, localImageID: photo.id, size: (0.4, 0.3))
            let star = builtIn(&draft, "strawberry-cookie")
            draft.rotate(star.id, by: -0.5)
            try diskLibrary.commit(draft)
            saved = draft.magnets
        }
        let relaunched = try SwiftDataFridgeStore.makeContainer(url: url)
        let reopened = MagnetLibrary(store: SwiftDataMagnetStore(container: relaunched), images: MagnetImageStore(directory: images.directory))
        XCTAssertEqual(try reopened.magnets(fridgeID: fridgeID), saved)
        XCTAssertNotNil(reopened.image(for: saved[0]), "photo file found again after relaunch")
        XCTAssertNotNil(reopened.image(for: saved[1]), "bundled artwork available")
    }

    func testCatalogIsScannedFromTheMagnetFolder() throws {
        // The app's folder: every bundled image is listed, in file-name order, with its file name as the ID.
        XCTAssertEqual(MagnetCatalog.shared.items.map(\.id), ["daisy", "pomeranian", "postcard-park", "strawberry-cookie"])
        for item in MagnetCatalog.shared.items {
            XCTAssertNotNil(MagnetCatalog.shared.image(id: item.id), item.id)
            let thumbnail = try XCTUnwrap(MagnetCatalog.shared.thumbnail(id: item.id))
            XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale, 300)
        }
        // A folder with new files (and non-images, which are ignored) needs no code changes.
        let folder = workDirectory.appendingPathComponent("Custom.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try imageData(width: 40, height: 40).write(to: folder.appendingPathComponent("10-cat.jpg"))
        try imageData(width: 40, height: 20, alpha: true).write(to: folder.appendingPathComponent("2-heart.png"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("README.txt"))
        let custom = MagnetCatalog(directory: folder)
        XCTAssertEqual(custom.items.map(\.id), ["2-heart", "10-cat"], "natural file-name order")
        XCTAssertEqual(custom.image(id: "2-heart")?.size, CGSize(width: 40, height: 20))
        XCTAssertNil(custom.image(id: "missing"))
        XCTAssertTrue(MagnetCatalog(directory: nil).items.isEmpty)
    }

    func testStylesCycleAndKeepTheirShape() throws {
        XCTAssertEqual(MagnetStyle.allCases.count, 7)
        var style = MagnetStyle.original
        var seen: [MagnetStyle] = []
        for _ in 0..<7 { seen.append(style); style = style.next }
        XCTAssertEqual(seen, [.original, .polaroid, .squareFrame, .roundedFrame, .stamp, .circle, .star])
        XCTAssertEqual(style, .original, "wraps around")

        XCTAssertEqual(MagnetStyle.circle.outerAspect(imageAspect: 0.5), 1)
        XCTAssertEqual(MagnetStyle.star.outerAspect(imageAspect: 2), 1)
        XCTAssertEqual(MagnetStyle.original.outerAspect(imageAspect: 0.75), 0.75)
        XCTAssertGreaterThan(MagnetStyle.polaroid.outerAspect(imageAspect: 0.5), 1, "polaroid is taller than wide")
        XCTAssertEqual(MagnetStyle.squareFrame.outerAspect(imageAspect: 1), 1, accuracy: 1e-9)

        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        XCTAssertEqual(magnet.style, .original)
        let width = magnet.width
        draft.setStyle(magnet.id, .circle, imageAspect: 1.3, doorAspect: 0.5)
        XCTAssertEqual(draft.magnet(magnet.id)?.style, .circle)
        XCTAssertEqual(draft.magnet(magnet.id)!.width, width, "size doesn't jump")
        XCTAssertEqual(draft.magnet(magnet.id)!.height, width * 0.5, accuracy: 1e-9, "square on screen")
        XCTAssertTrue(draft.hasChanges)
        let copy = try XCTUnwrap(draft.duplicate(magnet.id))
        XCTAssertEqual(copy.style, .circle)

        let (photoDraft, _) = try photoDraft(fridge.id)
        XCTAssertEqual(photoDraft.magnets.last?.style, .squareFrame, "photos start in a white frame")

        // Drawing: every style produces a usable picture area inside the magnet.
        for style in MagnetStyle.allCases {
            let shape = MagnetShape(style: style, size: CGSize(width: 100, height: 120))
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 100, height: 120).contains(shape.imageRect), "\(style)")
            XCTAssertGreaterThan(shape.imageRect.width, 0)
            if let outline = shape.outline {
                XCTAssertTrue(CGRect(x: -0.5, y: -0.5, width: 101, height: 121).contains(outline.bounds), "\(style)")
            }
        }
    }

    func testStyleIsSavedAndOldDataGetsDefaults() throws {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        let magnet = builtIn(&draft)
        draft.setStyle(magnet.id, .stamp, imageAspect: 1, doorAspect: 0.5)
        try library.commit(draft)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id).first?.style, .stamp)

        // A backup / record from before styles existed has no style: built-ins → 原始形狀, photos → 白框.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BackupCoding.encoder().encode(draft.magnets[0])) as? [String: Any])
        json["style"] = nil
        let decoded = try BackupCoding.decoder().decode(FridgeMagnet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.style, .original)
        json["source"] = "photo"
        json["localImageID"] = UUID().uuidString
        let photo = try BackupCoding.decoder().decode(FridgeMagnet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(photo.style, .squareFrame)
    }

    @MainActor
    func testTappingTheSelectedMagnetCyclesItsStyle() throws {
        var draft = MagnetDraft(fridgeID: fridge.id, magnets: [])
        _ = builtIn(&draft)
        try library.commit(draft)
        let editor = MagnetEditorViewController(fridge: fridge, library: library, magnets: try library.magnets(fridgeID: fridge.id))
        editor.loadViewIfNeeded()
        let id = draft.magnets[0].id
        editor.cycleStyle(id)
        XCTAssertEqual(editor.currentDraft.magnet(id)?.style, .polaroid)
        editor.cycleStyle(id)
        XCTAssertEqual(editor.currentDraft.magnet(id)?.style, .squareFrame)
        XCTAssertEqual(try library.magnets(fridgeID: fridge.id).first?.style, .original, "only saved on 儲存")
    }
}
