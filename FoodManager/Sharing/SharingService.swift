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
    /// A CloudKit error at one step (`code`: CKError code), so a failure can be reported precisely.
    case cloudKit(step: String, code: Int)

    var message: String {
        switch self {
        case .notAllowed(.requiresPremium): return "共享冰箱需要進階版。"
        case .notAllowed(.unsupportedSystem): return "共享冰箱需要 iOS 26 或更新版本。"
        case .notAllowed: return "目前無法使用共享冰箱。"
        case .syncUnavailable: return "請先在「設定」App 登入 iCloud，才能共享冰箱。"
        case .fridgeNotFound: return "找不到這台冰箱。"
        case .uploadIncomplete: return "上傳到 iCloud 沒有全部完成，冰箱沒有變更，請稍後再試。"
        case .shareFailed: return "無法建立 iCloud 共享，冰箱沒有變更，請稍後再試。"
        case let .cloudKit(step, code): return "共享沒有完成（\(step)失敗，CloudKit 錯誤 \(code)），冰箱沒有變更，請稍後再試。"
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
    /// Deletes both zones now and waits for the server (before retrying an interrupted conversion).
    func resetZones(fridgeID: UUID) async throws
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
    let personal: SwiftDataFridgeStore
    private let hasPremium: () -> Bool
    private let snapshots: ProtectionSnapshots?
    private let defaults: UserDefaults
    /// Request / member management on the server (nil before iOS 26 or in tests that don't need it).
    let administrator: ShareAdministering?
    /// Joining and leaving as a member (nil before iOS 26 or in tests that don't need it).
    let participantCloud: ParticipantCloud?
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Sharing")
    static let pendingRemovalKey = "sharing.pendingPersonalRemoval"

    init(policy: SharingPolicy, inventory: SharedInventory, cloud: SharingCloud, personal: SwiftDataFridgeStore,
         hasPremium: @escaping () -> Bool, snapshots: ProtectionSnapshots?, defaults: UserDefaults = .standard,
         administrator: ShareAdministering? = nil, participantCloud: ParticipantCloud? = nil) {
        self.administrator = administrator
        self.participantCloud = participantCloud
        self.policy = policy
        self.inventory = inventory
        self.cloud = cloud
        self.personal = personal
        self.hasPremium = hasPremium
        self.snapshots = snapshots
        self.defaults = defaults
        inventory.hiddenFridgeIDs = { [weak self] in self?.incompleteConversions() ?? [] }
    }

    /// Owned fridges that exist both as a personal fridge and in the shared store while their conversion never
    /// completed (e.g. records of a failed attempt came back from iCloud). The personal fridge stays the real one;
    /// sharing it again resumes the conversion from scratch.
    func incompleteConversions() -> Set<UUID> {
        guard let personalIDs = try? personal.existingIDs(), !personalIDs.isEmpty,
              let shared = try? inventory.store.fridges() else { return [] }
        let owned = Set(shared.filter { $0.role == .owner }.map(\.id))
        return owned.intersection(personalIDs).subtracting(pendingRemovals)
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
        let resuming = incompleteConversions().contains(fridgeID)
        if !resuming, let url = invitationURL(for: fridgeID) { return url }
        let gate = startGate
        guard gate == .allowed else { throw SharingServiceError.notAllowed(gate) }
        guard cloud.isReady else { throw SharingServiceError.syncUnavailable }
        if resuming {
            // Start over from the personal fridge: drop whatever an earlier attempt left on the server and here.
            do {
                try await cloud.resetZones(fridgeID: fridgeID)
            } catch {
                throw Self.failure(error, step: "清除上次未完成的共享")
            }
            try inventory.store.purgeFridge(fridgeID, keepPlaceholder: false)
        }

        let backup = try backups.makeBackup(allowMissingPhotos: false)
        guard let fridge = backup.fridges.first(where: { $0.id == fridgeID }) else { throw SharingServiceError.fridgeNotFound }
        try snapshots?.write(backup, kind: .beforeSharing)
        let magnets = backup.allMagnets.filter { $0.fridgeID == fridgeID }
        let imageIDs = Set(magnets.compactMap(\.localImageID))
        let images = Dictionary(backup.allMagnetImages.filter { imageIDs.contains($0.id) }.map { ($0.id, $0.data) }) { first, _ in first }

        let records = try inventory.importOwnedFridge(fridge, foods: backup.foods, magnets: magnets, images: images)
        let urls: (invitation: URL, structure: URL)
        var step = "上傳"
        do {
            try await cloud.upload(fridgeID: fridgeID, records: records)
            let unconfirmed = try inventory.unconfirmedRecords(of: fridgeID)
            guard unconfirmed == 0 else {
                logger.error("Sharing: \(unconfirmed, privacy: .public) record(s) not confirmed by the server")
                throw SharingServiceError.uploadIncomplete
            }
            step = "建立共享"
            urls = try await cloud.createShares(fridgeID: fridgeID, title: fridge.name)
            step = "儲存共享"
            try inventory.markShared(fridgeID, invitationURL: urls.invitation, structureURL: urls.structure)
        } catch {
            cloud.rollback(fridgeID: fridgeID)
            try? inventory.store.purgeFridge(fridgeID, keepPlaceholder: false)
            throw Self.failure(error, step: step)
        }

        pendingRemovals.insert(fridgeID)
        finishPendingRemovals()
        return urls.invitation
    }

    /// Logs the failing step with the CloudKit error code (never record contents or share URLs) and maps it to a
    /// message the user can report.
    private static func failure(_ error: Error, step: String) -> Error {
        let logger = Logger(subsystem: "FoodManager.HowCode", category: "Sharing")
        if let error = error as? SharingServiceError {
            logger.error("Sharing failed at \(step, privacy: .public): \(String(describing: error), privacy: .public)")
            return error
        }
        let ckError = error as? CKError
        let detail = ckError.map { error -> String in
            let partial = error.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.code.rawValue } ?? []
            return "code \(error.code.rawValue) partial \(Set(partial).sorted()) \(error.localizedDescription)"
        } ?? String(describing: type(of: error))
        logger.error("Sharing failed at \(step, privacy: .public): \(detail, privacy: .public)")
        if let ckError {
            let partialCode = ckError.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.code.rawValue }.first
            return SharingServiceError.cloudKit(step: step, code: partialCode ?? ckError.code.rawValue)
        }
        return SharingServiceError.shareFailed
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

    /// The engine runs; a missing iCloud account surfaces as a CloudKit error at upload (with its code).
    var isReady: Bool { engine.isRunning }

    func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {
        engine.queueZones(for: fridgeID)
        engine.queueSave(records, scope: .private)
        // Records the server reported as conflicting are queued again by the engine; send those too.
        for _ in 0..<3 {
            try await engine.sendChanges(scope: .private)
            if !engine.hasPendingSaves(records, scope: .private) { return }
        }
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

    func resetZones(fridgeID: UUID) async throws {
        engine.queueZoneDeletion(for: fridgeID)
        try await engine.sendChanges(scope: .private)
    }
}
