import CloudKit
import SwiftData
import UIKit
import XCTest
@testable import FoodManager

/// Phase 5E: personal data is local only (no CloudKit mirroring), the one-time migration from the mirrored store,
/// first-run state, and versioned manual iCloud backups. CloudKit is replaced by an in-memory store here; real
/// uploads and restores still need a signed-in device.
final class LocalOnlyBackupTests: XCTestCase {
    final class FakeBackupStore: ICloudBackupStore {
        var account: CloudAccountState = .available
        var records: [String: (version: ICloudBackupVersion, data: Data)] = [:]
        var failUpload = false
        var corruptDownloads = false
        var calls: [String] = []

        func accountState() async -> CloudAccountState { account }
        func versions() async throws -> [ICloudBackupVersion] { calls.append("versions"); return records.values.map(\.version) }
        func upload(_ version: ICloudBackupVersion, data: Data) async throws {
            calls.append("upload")
            if failUpload { throw CKError(.networkFailure) }
            records[version.id] = (version, data)
        }
        func download(id: String) async throws -> Data {
            calls.append("download")
            guard let data = records[id]?.data else { throw CKError(.unknownItem) }
            return corruptDownloads ? data.dropLast(3) : data
        }
        func delete(ids: [String]) async throws {
            calls.append("delete")
            ids.forEach { records[$0] = nil }
        }
    }

    private var work: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("LocalOnly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "LocalOnly-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func backupService(_ container: ModelContainer) -> BackupService {
        BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                      preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: InMemoryFridgeSelectionStore()),
                      recoveryDirectory: nil, applicationVersion: "test")
    }

    private func sampleBackup(fridges: Int = 1, food: String = "牛奶") throws -> FoodManagerBackup {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let store = SwiftDataFridgeStore(container: container)
        let first = try store.loadAll()[0].fridge
        for index in 1..<max(fridges, 1) { try store.create(FridgeFactory.makeDefault(name: "冰箱\(index)")) }
        let now = Date()
        try SwiftDataFoodStore(container: container).upsert(
            FoodItem(id: UUID(), name: food, categoryID: "dairy", quantity: 1, unit: "瓶", storedAt: now, expirationDate: nil,
                     storageReminderDays: nil, fridgeID: first.id, compartmentID: first.cabinetCompartments[0].id,
                     createdAt: now, updatedAt: now, consumedAt: nil))
        return try backupService(container).makeBackup()
    }

    // MARK: Local only

    func testPersonalStoreNeverMirrorsToCloudKit() throws {
        for container in [try SwiftDataFridgeStore.makeContainer(inMemory: true),
                          try SwiftDataFridgeStore.makeContainer(url: work.appendingPathComponent("a.store"))] {
            for configuration in container.configurations {
                XCTAssertNil(configuration.cloudKitContainerIdentifier, "personal data has no CloudKit container")
            }
        }
    }

    func testStoreMirroredByEarlierVersionsOpensLocalOnlyWithEverything() throws {
        let url = work.appendingPathComponent("default.store")
        let fridge = FridgeFactory.makeDefault(name: "舊版冰箱")
        do {
            // How 4.4–5D opened the store: mirrored to the private database.
            let mirrored = ModelConfiguration(schema: SwiftDataFridgeStore.schema, url: url,
                                              cloudKitDatabase: .private(CloudSyncConstants.containerIdentifier))
            let container = try ModelContainer(for: SwiftDataFridgeStore.schema, configurations: [mirrored])
            try SwiftDataFridgeStore(container: container).create(fridge)
        }
        let local = SwiftDataFridgeStore(container: try SwiftDataFridgeStore.makeContainer(url: url))
        XCTAssertEqual(try local.loadExisting().map(\.fridge.id), [fridge.id], "same IDs, nothing lost")
        try local.rename(fridgeID: fridge.id, to: "本機")
        let reopened = SwiftDataFridgeStore(container: try SwiftDataFridgeStore.makeContainer(url: url))
        XCTAssertEqual(try reopened.loadExisting().first?.fridge.name, "本機", "writable, persists across relaunch")
    }

    func testDeletedFridgeStaysDeletedAcrossRelaunches() throws {
        // The reported regression: a deleted fridge came back from the old iCloud mirror.
        let url = work.appendingPathComponent("default.store")
        let pantry = FridgeFactory.makeDefault(name: "儲藏室")
        do {
            let store = SwiftDataFridgeStore(container: try SwiftDataFridgeStore.makeContainer(url: url))
            let main = try store.loadAll()[0].fridge
            try store.create(pantry)
            try store.deleteFridge(pantry.id, moveHistoryTo: main.id)
        }
        for _ in 0..<3 { // relaunch, foreground, … — nothing can bring it back
            let session = try AppBootstrap.makeSession(container: try SwiftDataFridgeStore.makeContainer(url: url), mode: .inMemoryForTesting,
                                                       selection: InMemoryFridgeSelectionStore()).get()
            XCTAssertFalse(session.directory.fridges.contains { $0.id == pantry.id })
            XCTAssertEqual(session.directory.fridges.count, 1)
        }
    }

    // MARK: Migration and first run

    func testExistingInstallationIsProtectedAndNeverAsked() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        let prefs = UserDefaultsPreferencesBackupStore(defaults: defaults, selection: InMemoryFridgeSelectionStore())
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container, snapshots: snapshots, magnetImages: nil,
                                                      defaults: defaults, preferences: prefs), .existingData)
        XCTAssertEqual(FirstRunState.load(defaults), .decided)
        let copy = try XCTUnwrap(snapshots.list().first { $0.kind == .beforeLocalOnly })
        XCTAssertNoThrow(try BackupService.readBackup(at: copy.url), "a verified, restorable copy")
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container, snapshots: snapshots, magnetImages: nil,
                                                      defaults: defaults, preferences: prefs), .alreadyDone)
    }

    func testNewInstallationMayBeOfferedABackupOnce() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let snapshots = ProtectionSnapshots(directory: work.appendingPathComponent("Protection"))
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container, snapshots: snapshots, magnetImages: nil, defaults: defaults),
                       .freshInstall)
        XCTAssertEqual(FirstRunState.load(defaults), .pending)
        XCTAssertTrue(snapshots.list().isEmpty, "nothing to protect")
        FirstRunState.decided.save(defaults)
        // Deleting fridges later never turns this back into a new installation.
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container, snapshots: snapshots, magnetImages: nil, defaults: defaults),
                       .alreadyDone)
        XCTAssertEqual(FirstRunState.load(defaults), .decided)
    }

    func testFailedProtectionCopyIsRetriedNextLaunch() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: container).loadAll()
        let blocked = work.appendingPathComponent("file")
        try Data([1]).write(to: blocked) // a file where the directory should be
        let prefs = UserDefaultsPreferencesBackupStore(defaults: defaults, selection: InMemoryFridgeSelectionStore())
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container, snapshots: ProtectionSnapshots(directory: blocked),
                                                      magnetImages: nil, defaults: defaults, preferences: prefs), .snapshotFailed)
        XCTAssertEqual(LocalOnlyMigration.runIfNeeded(container: container,
                                                      snapshots: ProtectionSnapshots(directory: work.appendingPathComponent("P")),
                                                      magnetImages: nil, defaults: defaults, preferences: prefs), .existingData)
    }

    // MARK: Manual iCloud backups

    func testBackupIsUploadedVerifiedAndListed() async throws {
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        XCTAssertNil(service.lastVerifiedBackup)
        let backup = try sampleBackup(fridges: 2)
        let version = try await service.upload(backup)
        XCTAssertEqual(version.fridgeCount, 2)
        XCTAssertEqual(version.activeFoodCount, 1)
        XCTAssertEqual(store.calls.prefix(2), ["upload", "download"], "verified by reading it back")
        XCTAssertNotNil(service.lastVerifiedBackup)
        let listed = try await service.versions()
        XCTAssertEqual(listed.map(\.id), [version.id])
        let restored = try await service.download(version)
        XCTAssertEqual(restored.fridges.map(\.id), backup.fridges.map(\.id))
    }

    func testOnlyTheThreeNewestVersionsAreKept() async throws {
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        var ids: [String] = []
        for index in 0..<5 {
            var backup = try sampleBackup(food: "食材\(index)")
            backup.exportedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60)
            ids.append(try await service.upload(backup).id)
        }
        let remaining = try await service.versions()
        XCTAssertEqual(remaining.map(\.id), Array(ids.suffix(3).reversed()), "newest first, oldest two removed")
    }

    func testInterruptedUploadKeepsEveryEarlierVersion() async throws {
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        let first = try await service.upload(try sampleBackup())
        let verifiedAt = service.lastVerifiedBackup
        store.failUpload = true
        do {
            _ = try await service.upload(try sampleBackup(food: "新的"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .networkUnavailable)
        }
        let versions = try await service.versions()
        XCTAssertEqual(versions.map(\.id), [first.id])
        XCTAssertEqual(service.lastVerifiedBackup, verifiedAt, "never marked backed up before verification")
    }

    func testUploadThatDoesntVerifyIsDiscarded() async throws {
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        let good = try await service.upload(try sampleBackup())
        store.corruptDownloads = true
        do {
            _ = try await service.upload(try sampleBackup(food: "新的"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .verificationFailed)
        }
        XCTAssertEqual(Array(store.records.keys), [good.id], "the bad copy is removed, the good one stays")
    }

    func testCorruptedDownloadChangesNothing() async throws {
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        let version = try await service.upload(try sampleBackup())
        store.corruptDownloads = true
        do {
            _ = try await service.download(version)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .corrupted)
        }
        // Valid checksum but not a valid backup: also refused.
        let junk = Data("{\"formatVersion\": 99}".utf8)
        let fake = ICloudBackupVersion(id: "junk", createdAt: .now, appVersion: "x", formatVersion: 99, fridgeCount: 0, activeFoodCount: 0,
                                       historyCount: 0, magnetCount: 0, imageCount: 0, byteCount: junk.count,
                                       sha256: ICloudBackupVersion.digest(junk))
        store.corruptDownloads = false
        store.records["junk"] = (fake, junk)
        do {
            _ = try await service.download(fake)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .corrupted)
        }
    }

    func testNoAccountIsExplainedAndNothingIsTouched() async throws {
        let store = FakeBackupStore()
        store.account = .noAccount
        let service = ICloudBackupService(store: store, defaults: defaults)
        do {
            _ = try await service.versions()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .noAccount)
        }
        do {
            _ = try await service.upload(try sampleBackup())
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .noAccount)
        }
        XCTAssertTrue(store.calls.isEmpty)
        store.account = .temporarilyUnavailable
        do {
            _ = try await service.versions()
            XCTFail("an unreachable iCloud is never taken for \"no backups\"")
        } catch {
            XCTAssertEqual(error as? ICloudBackupError, .networkUnavailable)
        }
    }

    func testRestoreFromICloudReplacesPersonalDataWithPhotos() async throws {
        // Source device: a photo magnet.
        let source = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: source).loadAll()[0].fridge
        let photoID = UUID()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let magnet = FridgeMagnet(id: UUID(), fridgeID: fridge.id, source: .photo, builtInAssetID: nil, localImageID: photoID,
                                  centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, rotation: 0, zIndex: 0, createdAt: .now, updatedAt: .now)
        try SwiftDataMagnetStore(container: source).replaceMagnets([magnet], fridgeID: fridge.id, newImages: [photoID: png])
        let store = FakeBackupStore()
        let service = ICloudBackupService(store: store, defaults: defaults)
        let version = try await service.upload(try backupService(source).makeBackup())

        // Reinstalled device: an empty default fridge, then the user picks the version and confirms.
        let target = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        _ = try SwiftDataFridgeStore(container: target).loadAll()
        let downloaded = try await service.download(version)
        try backupService(target).restore(downloaded)
        XCTAssertEqual(try SwiftDataFridgeStore(container: target).loadExisting().map(\.fridge.id), [fridge.id])
        XCTAssertEqual(try SwiftDataMagnetStore(container: target).imageData(id: photoID), png, "custom photo restored")
    }

    func testFileImportNeverReachesICloud() throws {
        let store = FakeBackupStore()
        _ = ICloudBackupService(store: store, defaults: defaults)
        let target = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        try backupService(target).restore(try sampleBackup())
        XCTAssertTrue(store.calls.isEmpty, "importing a file uploads nothing")
    }
}
