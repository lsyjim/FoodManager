import CloudKit
import Foundation
import os

// Participant side of Phase 5D-4. Opening an invitation link:
// 1. If the server says this account is already a participant (the owner approved it), accept the inventory share.
// 2. Otherwise send an access request (`CKShareRequestAccessOperation`) and remember the link: nothing about the
//    fridge is readable until the owner approves. The app checks again later (foreground, management screen).
// 3. Once the inventory zone is readable, its StructureLink names the read-only structure share. It is joined only if
//    that share really is this fridge's structure zone of the same owner (a member could have written the link).
// Leaving deletes this member's share records in the shared database, then the local copy.

/// What the server says about a share link for this account.
struct ShareInvitationInfo: Equatable {
    let zoneID: CKRecordZone.ID
    let isOwner: Bool
    /// Added by the owner (approved): may accept.
    let isMember: Bool
}

/// The CloudKit side of joining (live: `CloudKitParticipantCloud`; tests: a fake).
protocol ParticipantCloud: AnyObject {
    /// Throws when this account can't see the share (not approved yet, or it doesn't exist — the server doesn't say).
    func metadata(for url: URL) async throws -> ShareInvitationInfo
    func accept(_ url: URL) async throws
    func requestAccess(_ url: URL) async throws
    func leave(fridgeID: UUID, ownerName: String) async throws
    func fetchNow() async throws
}

enum JoinOutcome: Equatable {
    case joined(UUID)
    case waitingForApproval
    case alreadyJoined(UUID)
    /// The link belongs to one of this user's own fridges.
    case ownFridge
}

struct InactiveSharedEntry: Equatable {
    let id: UUID
    let name: String
    let ownership: SharedFridgeOwnership
    /// An access request (cancel) rather than a fridge (leave / remove).
    let isRequest: Bool
}

enum JoinError: Error, Equatable {
    case invalidLink
    case limitReached

    var message: String {
        switch self {
        case .invalidLink: return "這不是冰箱管理員的共享冰箱連結。"
        case .limitReached: return FridgePolicy.limitMessage + "（包含共享與等待同意中的冰箱）"
        }
    }
}

extension SharingService {
    private var joinLogger: Logger { Logger(subsystem: "FoodManager.HowCode", category: "Sharing") }

    func join(url: URL) async throws -> JoinOutcome {
        let gate = policy.joinGate
        guard gate == .allowed else { throw SharingServiceError.notAllowed(gate) }
        guard SharedRecordCoder.isValidShareURL(url) else { throw JoinError.invalidLink }
        guard let participantCloud else { throw SharingServiceError.syncUnavailable }

        if let info = try? await participantCloud.metadata(for: url) {
            guard let zone = SharedZone.parse(info.zoneID), zone.kind == .inventory else { throw JoinError.invalidLink }
            if info.isOwner { return .ownFridge }
            if inventory.ownership(of: zone.fridgeID) == .sharedParticipant { return .alreadyJoined(zone.fridgeID) }
            if info.isMember {
                guard hasFreeSlot(forLink: url) else { throw JoinError.limitReached }
                try await participantCloud.accept(url)
                try inventory.store.addJoiningFridge(id: zone.fridgeID, ownerName: info.zoneID.ownerName)
                try removeInvitations(for: url)
                try? await participantCloud.fetchNow()
                await continueStructureJoins()
                return .joined(zone.fridgeID)
            }
        }
        guard hasFreeSlot(forLink: url) else { throw JoinError.limitReached }
        try await participantCloud.requestAccess(url)
        try inventory.store.addInvitation(url: url)
        return .waitingForApproval
    }

    /// Joins every request the owner approved since the last check. Returns the fridges joined.
    @discardableResult
    func checkPendingInvitations() async -> [UUID] {
        guard policy.joinGate == .allowed, let participantCloud, let invitations = try? inventory.store.invitations() else { return [] }
        var joined: [UUID] = []
        for invitation in invitations {
            guard let info = try? await participantCloud.metadata(for: invitation.url), info.isMember, !info.isOwner,
                  let zone = SharedZone.parse(info.zoneID), zone.kind == .inventory else { continue }
            do {
                try await participantCloud.accept(invitation.url)
                try inventory.store.addJoiningFridge(id: zone.fridgeID, ownerName: info.zoneID.ownerName)
                try inventory.store.removeInvitation(id: invitation.id)
                joined.append(zone.fridgeID)
            } catch {
                joinLogger.error("Joining an approved shared fridge failed; will retry")
            }
        }
        if !joined.isEmpty { try? await participantCloud.fetchNow() }
        await continueStructureJoins()
        return joined
    }

    /// Joins the read-only structure share of fridges whose inventory is readable, after checking the link really
    /// points at that fridge's structure zone of the same owner.
    func continueStructureJoins() async {
        guard let participantCloud, let pending = try? inventory.store.pendingStructureJoins(), !pending.isEmpty else { return }
        var joinedAny = false
        for join in pending {
            let expected = SharedZone.id(fridgeID: join.fridgeID, kind: .structure, ownerName: join.ownerName)
            guard let info = try? await participantCloud.metadata(for: join.url), info.zoneID == expected,
                  info.isMember, !info.isOwner else {
                joinLogger.notice("Structure link not usable (yet)")
                continue
            }
            if (try? await participantCloud.accept(join.url)) != nil { joinedAny = true }
        }
        if joinedAny { try? await participantCloud.fetchNow() }
    }

    /// Stops waiting for an approval on this device (CloudKit has no way to withdraw a sent request).
    func cancelInvitation(_ id: UUID) throws {
        try inventory.store.removeInvitation(id: id)
    }

    func invitations() -> [SharedInvitation] {
        (try? inventory.store.invitations()) ?? []
    }

    /// Shared entries that hold a slot or need attention but can't be opened: requests waiting for approval, joins
    /// in progress and fridges that are no longer accessible.
    func inactiveEntries() -> [InactiveSharedEntry] {
        let waiting = invitations().map { InactiveSharedEntry(id: $0.id, name: "邀請連結", ownership: .pendingInvitation, isRequest: true) }
        let fridges = ((try? inventory.store.fridges()) ?? [])
            .filter { $0.ownership == .pendingInvitation || $0.ownership == .unavailableOrRevoked }
            .map { InactiveSharedEntry(id: $0.id, name: $0.name.isEmpty ? "共享冰箱" : $0.name, ownership: $0.ownership, isRequest: false) }
        return waiting + fridges
    }

    /// What backups must leave alone: every shared fridge, and the slots shared fridges and requests hold.
    func backupExclusion() -> SharedFridgeExclusion {
        let fridges = (try? inventory.store.fridges()) ?? []
        return SharedFridgeExclusion(fridgeIDs: Set(fridges.map(\.id)),
                                     reservedSlots: FridgePolicy.fridgeCount(personal: 0, shared: fridges.map(\.ownership)) + invitations().count)
    }

    /// A member leaves: their access ends on the server first, then the local copy is removed.
    func leave(fridgeID: UUID) async throws {
        guard inventory.role(of: fridgeID) == .participant, let summary = try inventory.store.fridges().first(where: { $0.id == fridgeID }) else {
            throw SharedStoreError.ownerOnly
        }
        if summary.ownership != .unavailableOrRevoked {
            guard let participantCloud else { throw SharingServiceError.syncUnavailable }
            try await participantCloud.leave(fridgeID: fridgeID, ownerName: inventory.zoneOwnerName(of: fridgeID) ?? "")
        }
        try inventory.store.purgeFridge(fridgeID, keepPlaceholder: false)
    }

    /// Owned + shared + joined + waiting must stay within the limit. A link that already waits keeps its own slot.
    private func hasFreeSlot(forLink url: URL) -> Bool {
        let personalCount = (try? personal.loadExisting().count) ?? FridgePolicy.maxRefrigerators
        let shared = (try? inventory.store.ownerships()) ?? []
        let waiting = invitations().filter { $0.url != url }.count
        return FridgePolicy.fridgeCount(personal: personalCount, shared: shared) + waiting < FridgePolicy.maxRefrigerators
    }

    private func removeInvitations(for url: URL) throws {
        for invitation in invitations() where invitation.url == url {
            try inventory.store.removeInvitation(id: invitation.id)
        }
    }
}

// MARK: - Live CloudKit

@available(iOS 26.0, *)
final class CloudKitParticipantCloud: ParticipantCloud {
    private let container: CKContainer
    private let engine: SharedSyncEngine

    init(container: CKContainer, engine: SharedSyncEngine) {
        self.container = container
        self.engine = engine
    }

    func metadata(for url: URL) async throws -> ShareInvitationInfo {
        let metadata = try await fetchMetadata(url)
        let status = metadata.participantStatus
        return ShareInvitationInfo(zoneID: metadata.share.recordID.zoneID, isOwner: metadata.participantRole == .owner,
                                   isMember: status == .pending || status == .accepted)
    }

    func accept(_ url: URL) async throws {
        let metadata = try await fetchMetadata(url)
        guard metadata.participantStatus != .accepted else { return }
        let results = try await container.accept([metadata])
        if let result = results[metadata] { _ = try result.get() }
    }

    func requestAccess(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKShareRequestAccessOperation(shareURLs: [url])
            var perShare: Result<Void, Error> = .success(())
            operation.perShareAccessRequestResultBlock = { _, result in perShare = result }
            operation.shareAccessRequestResultBlock = { result in
                switch (result, perShare) {
                case let (.failure(error), _), let (_, .failure(error)): continuation.resume(throwing: error)
                default: continuation.resume()
                }
            }
            container.add(operation)
        }
    }

    func leave(fridgeID: UUID, ownerName: String) async throws {
        let ids = [SharedZoneKind.inventory, .structure].map {
            CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: SharedZone.id(fridgeID: fridgeID, kind: $0, ownerName: ownerName))
        }
        let (_, results) = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: ids, atomically: false)
        for result in results.values {
            do {
                try result.get()
            } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
                continue // not joined / already gone
            }
        }
    }

    func fetchNow() async throws {
        try await engine.fetchChanges()
    }

    private func fetchMetadata(_ url: URL) async throws -> CKShare.Metadata {
        let results = try await container.shareMetadatas(for: [url])
        guard let result = results[url] ?? results.values.first else { throw CKError(.unknownItem) }
        return try result.get()
    }
}
