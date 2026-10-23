import CloudKit
import Foundation
import os

enum SharingServiceError: Error, Equatable {
    case notAllowed(SharingGate)
    case syncUnavailable
    case fridgeNotFound
    /// The server didn't confirm every record; nothing changed for the user.
    case uploadIncomplete
    case shareFailed

    var message: String {
        switch self {
        case .notAllowed(.requiresPremium): return "共享冰箱需要進階版。"
        case .notAllowed(.unsupportedSystem): return "共享冰箱需要 iOS 26 或更新版本。"
        case .notAllowed: return "目前無法使用共享冰箱。"
        case .syncUnavailable: return "請先登入 iCloud 並開啟「iCloud 自動同步」，才能共享冰箱。"
        case .fridgeNotFound: return "找不到這台冰箱。"
        case .uploadIncomplete, .shareFailed: return "無法連線到 iCloud，冰箱沒有變更，請稍後再試。"
        }
    }
}

/// The CloudKit side of starting to share (live: `CloudKitSharingCloud`; tests: a fake).
protocol SharingCloud: AnyObject {
    var isReady: Bool { get }
    /// Creates the fridge's two zones, uploads `records` and waits for the server.
    func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws
    /// Creates (or fetches existing) zone-wide shares: structure read-only, inventory by approved request only.
    func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL)
    /// Removes both zones again (a conversion that didn't complete).
    func rollback(fridgeID: UUID)
}

/// Owner side of Phase 5D-2: turns a personal fridge into a shared one and hands out the invitation link.
///
/// Order (each step only after the previous one succeeded; any failure leaves the personal fridge untouched):
/// 1. verified full backup → `BeforeSharing-Backup.json` protection snapshot;
/// 2. copy into `Shared.store`, create both zones, upload, confirm every record;
/// 3. create both shares (`publicPermission = .none`; access only by approved request);
/// 4. only then remove the personal rows (SwiftData mirrors the removal to the owner's other devices, which get
///    the fridge from the private custom zones instead).
final class SharingService {
    let policy: SharingPolicy
    let inventory: SharedInventory
    private let cloud: SharingCloud
    private let personal: SwiftDataFridgeStore
    private let hasPremium: () -> Bool
    private let snapshots: ProtectionSnapshots?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Sharing")
    static let pendingRemovalKey = "sharing.pendingPersonalRemoval"

    init(policy: SharingPolicy, inventory: SharedInventory, cloud: SharingCloud, personal: SwiftDataFridgeStore,
         hasPremium: @escaping () -> Bool, snapshots: ProtectionSnapshots?, defaults: UserDefaults = .standard) {
        self.policy = policy
        self.inventory = inventory
        self.cloud = cloud
        self.personal = personal
        self.hasPremium = hasPremium
        self.snapshots = snapshots
        self.defaults = defaults
    }

    var startGate: SharingGate { policy.startSharingGate(hasPremium: hasPremium()) }

    /// Whether the "share this fridge" action applies (a personal fridge; the gate decides what happens on tap).
    func canOfferSharing(_ fridgeID: UUID) -> Bool {
        startGate != .disabled && !inventory.contains(fridgeID)
    }

    func ownership(of fridgeID: UUID) -> SharedFridgeOwnership {
        inventory.ownership(of: fridgeID) ?? .personalOwned
    }

    func invitationURL(for fridgeID: UUID) -> URL? { inventory.invitationURL(for: fridgeID) }

    /// Shares a personal fridge and returns the invitation link (also if it was already shared).
    func share(fridgeID: UUID, backups: BackupService) async throws -> URL {
        if let url = invitationURL(for: fridgeID) { return url }
        let gate = startGate
        guard gate == .allowed else { throw SharingServiceError.notAllowed(gate) }
        guard cloud.isReady else { throw SharingServiceError.syncUnavailable }

        let backup = try backups.makeBackup(allowMissingPhotos: false)
        guard let fridge = backup.fridges.first(where: { $0.id == fridgeID }) else { throw SharingServiceError.fridgeNotFound }
        try snapshots?.write(backup, kind: .beforeSharing)
        let magnets = backup.allMagnets.filter { $0.fridgeID == fridgeID }
        let imageIDs = Set(magnets.compactMap(\.localImageID))
        let images = Dictionary(backup.allMagnetImages.filter { imageIDs.contains($0.id) }.map { ($0.id, $0.data) }) { first, _ in first }

        let records = try inventory.importOwnedFridge(fridge, foods: backup.foods, magnets: magnets, images: images)
        let urls: (invitation: URL, structure: URL)
        do {
            try await cloud.upload(fridgeID: fridgeID, records: records)
            guard try inventory.unconfirmedRecords(of: fridgeID) == 0 else { throw SharingServiceError.uploadIncomplete }
            urls = try await cloud.createShares(fridgeID: fridgeID, title: fridge.name)
            try inventory.markShared(fridgeID, invitationURL: urls.invitation, structureURL: urls.structure)
        } catch {
            cloud.rollback(fridgeID: fridgeID)
            try? inventory.store.purgeFridge(fridgeID, keepPlaceholder: false)
            logger.error("Sharing a fridge did not complete; personal data unchanged")
            throw (error as? SharingServiceError) ?? SharingServiceError.shareFailed
        }

        pendingRemovals.insert(fridgeID)
        finishPendingRemovals()
        return urls.invitation
    }

    /// Removes personal copies of fridges whose sharing completed (retried at launch if it failed before).
    func finishPendingRemovals() {
        for id in pendingRemovals where inventory.ownership(of: id) == .sharedOwned {
            do {
                try personal.removeFridgeAfterSharing(id)
                pendingRemovals.remove(id)
            } catch FridgeStoreError.fridgeNotFound {
                pendingRemovals.remove(id)
            } catch {
                logger.error("Removing the personal copy of a shared fridge failed; will retry")
            }
        }
    }

    private var pendingRemovals: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.pendingRemovalKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.pendingRemovalKey) }
    }
}

/// Live `SharingCloud` over `SharedSyncEngine` and the private database.
final class CloudKitSharingCloud: SharingCloud {
    private let engine: SharedSyncEngine

    init(engine: SharedSyncEngine) { self.engine = engine }

    var isReady: Bool { engine.isRunning }

    func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {
        engine.queueZones(for: fridgeID)
        engine.queueSave(records, scope: .private)
        try await engine.sendChanges(scope: .private)
    }

    func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) {
        guard #available(iOS 26.0, *) else { throw SharingServiceError.notAllowed(.unsupportedSystem) }
        let database = engine.privateDatabase
        var shares: [SharedZoneKind: CKShare] = [:]
        var toSave: [CKShare] = []
        for kind in [SharedZoneKind.structure, .inventory] {
            let zoneID = SharedZone.id(fridgeID: fridgeID, kind: kind)
            if let existing = try? await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare {
                shares[kind] = existing
                continue
            }
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = title
            // Nobody gets in by holding the link: participants are added only when the owner approves a request.
            share.publicPermission = .none
            if kind == .inventory { share.allowsAccessRequests = true }
            toSave.append(share)
        }
        if !toSave.isEmpty {
            let (results, _) = try await database.modifyRecords(saving: toSave, deleting: [])
            for (id, result) in results {
                guard let share = try result.get() as? CKShare, let zone = SharedZone.parse(id.zoneID) else { continue }
                shares[zone.kind] = share
            }
        }
        guard let invitation = shares[.inventory]?.url, let structure = shares[.structure]?.url else {
            throw SharingServiceError.shareFailed
        }
        return (invitation, structure)
    }

    func rollback(fridgeID: UUID) {
        engine.queueZoneDeletion(for: fridgeID)
    }
}
