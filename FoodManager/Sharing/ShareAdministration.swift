import CloudKit
import Contacts
import Foundation

// Owner side of Phase 5D-3: access requests (approve / deny / block), members (remove), blocked users (unblock),
// turning requests off, and stopping sharing. Everything is applied to the server's CKShare records, which is
// where CloudKit enforces it; the screens only show what the server returned.

/// A person as shown to the owner. `id` is only meaningful within one `ShareOverview` fetch.
struct SharePerson: Equatable {
    let id: String
    let name: String
    /// Email or phone the requester asked from (requesters only; helps the owner recognise them).
    let contactDetail: String?
}

struct ShareOverview: Equatable {
    var requesters: [SharePerson]
    var members: [SharePerson]
    var blocked: [SharePerson]
    var allowsAccessRequests: Bool
}

/// The CloudKit operations (live: `CloudKitShareAdministrator`; tests: a fake).
protocol ShareAdministering: AnyObject {
    func overview(fridgeID: UUID) async throws -> ShareOverview
    /// Adds the requester to the inventory share (read-write) and the structure share (read-only).
    func approve(requesterID: String, fridgeID: UUID) async throws
    func deny(requesterID: String, fridgeID: UUID) async throws
    func block(requesterID: String, fridgeID: UUID) async throws
    func unblock(blockedID: String, fridgeID: UUID) async throws
    /// Removes a member from both shares.
    func remove(memberID: String, fridgeID: UUID) async throws
    func setAllowsAccessRequests(_ allowed: Bool, fridgeID: UUID) async throws
    /// Deletes both shares: every member loses access at once.
    func stopSharing(fridgeID: UUID) async throws
}

enum ShareAdministrationError: Error, Equatable {
    case notOwner
    /// The request / member changed on the server in the meantime (shown after a refresh).
    case personGone
    case unsupportedSystem
    case serverFailure

    var message: String {
        switch self {
        case .notOwner: return "只有冰箱主人可以管理成員。"
        case .personGone: return "這筆資料已經變更，已重新整理。"
        case .unsupportedSystem: return "管理加入申請需要 iOS 26 或更新版本。"
        case .serverFailure: return "無法連線到 iCloud，沒有任何變更，請稍後再試。"
        }
    }
}

extension SharingService {
    private func requireOwner(_ fridgeID: UUID) throws -> ShareAdministering {
        guard inventory.ownership(of: fridgeID) == .sharedOwned, let administrator else { throw ShareAdministrationError.notOwner }
        return administrator
    }

    func shareOverview(fridgeID: UUID) async throws -> ShareOverview {
        try await requireOwner(fridgeID).overview(fridgeID: fridgeID)
    }

    func approve(_ requester: SharePerson, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).approve(requesterID: requester.id, fridgeID: fridgeID)
    }

    func deny(_ requester: SharePerson, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).deny(requesterID: requester.id, fridgeID: fridgeID)
    }

    func block(_ requester: SharePerson, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).block(requesterID: requester.id, fridgeID: fridgeID)
    }

    func unblock(_ person: SharePerson, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).unblock(blockedID: person.id, fridgeID: fridgeID)
    }

    func remove(_ member: SharePerson, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).remove(memberID: member.id, fridgeID: fridgeID)
    }

    func setAllowsAccessRequests(_ allowed: Bool, fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).setAllowsAccessRequests(allowed, fridgeID: fridgeID)
    }

    /// Members lose access; the fridge and everything in it stays with the owner.
    func stopSharing(fridgeID: UUID) async throws {
        try await requireOwner(fridgeID).stopSharing(fridgeID: fridgeID)
        try inventory.markUnshared(fridgeID)
    }
}

// MARK: - Live CloudKit

@available(iOS 26.0, *)
final class CloudKitShareAdministrator: ShareAdministering {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    init(container: CKContainer) {
        self.container = container
    }

    func overview(fridgeID: UUID) async throws -> ShareOverview {
        let share = try await fetchShare(fridgeID, .inventory)
        let owner = share.owner.userIdentity.userRecordID
        return ShareOverview(
            requesters: share.requesters.map { requester in
                SharePerson(id: Self.key(requester.participantLookupInfo),
                            name: Self.name(requester.userIdentity.nameComponents, contact: requester.contact),
                            contactDetail: requester.participantLookupInfo.emailAddress ?? requester.participantLookupInfo.phoneNumber)
            },
            members: share.participants
                .filter { $0.role != .owner && $0.userIdentity.userRecordID != owner }
                .map { SharePerson(id: $0.participantID, name: Self.name($0.userIdentity.nameComponents, contact: nil), contactDetail: nil) },
            blocked: share.blockedIdentities.map { identity in
                SharePerson(id: Self.key(identity.userIdentity), name: Self.name(identity.userIdentity.nameComponents, contact: identity.contact),
                            contactDetail: nil)
            },
            allowsAccessRequests: share.allowsAccessRequests)
    }

    func approve(requesterID: String, fridgeID: UUID) async throws {
        let inventory = try await fetchShare(fridgeID, .inventory)
        let structure = try await fetchShare(fridgeID, .structure)
        guard let requester = inventory.requesters.first(where: { Self.key($0.participantLookupInfo) == requesterID }) else {
            throw ShareAdministrationError.personGone
        }
        // One participant object per share (CloudKit doesn't allow adding the same instance to two shares).
        let lookup = requester.participantLookupInfo
        guard let reader = try await container.shareParticipants(for: [lookup])[lookup]?.get(),
              let editor = try await container.shareParticipants(for: [lookup])[lookup]?.get() else {
            throw ShareAdministrationError.personGone
        }
        reader.permission = .readOnly
        structure.addParticipant(reader)
        editor.permission = .readWrite
        inventory.addParticipant(editor)
        // Structure first: by the time the member can read the food, the read-only structure share includes them.
        try await save(structure)
        do {
            try await save(inventory)
        } catch {
            structure.removeParticipant(reader)
            try? await save(structure)
            throw error
        }
    }

    func deny(requesterID: String, fridgeID: UUID) async throws {
        let share = try await fetchShare(fridgeID, .inventory)
        guard let requester = share.requesters.first(where: { Self.key($0.participantLookupInfo) == requesterID }) else {
            throw ShareAdministrationError.personGone
        }
        share.denyRequesters([requester])
        try await save(share)
    }

    func block(requesterID: String, fridgeID: UUID) async throws {
        let share = try await fetchShare(fridgeID, .inventory)
        guard let requester = share.requesters.first(where: { Self.key($0.participantLookupInfo) == requesterID }) else {
            throw ShareAdministrationError.personGone
        }
        share.blockRequesters([requester])
        try await save(share)
    }

    func unblock(blockedID: String, fridgeID: UUID) async throws {
        let share = try await fetchShare(fridgeID, .inventory)
        guard let identity = share.blockedIdentities.first(where: { Self.key($0.userIdentity) == blockedID }) else {
            throw ShareAdministrationError.personGone
        }
        share.unblockIdentities([identity])
        try await save(share)
    }

    func remove(memberID: String, fridgeID: UUID) async throws {
        let inventory = try await fetchShare(fridgeID, .inventory)
        guard let member = inventory.participants.first(where: { $0.participantID == memberID }), member.role != .owner else {
            throw ShareAdministrationError.personGone
        }
        let userRecordID = member.userIdentity.userRecordID
        inventory.removeParticipant(member)
        // Food access ends first, then the read-only structure share.
        try await save(inventory)
        let structure = try await fetchShare(fridgeID, .structure)
        if let userRecordID, let reader = structure.participants.first(where: { $0.userIdentity.userRecordID == userRecordID }),
           reader.role != .owner {
            structure.removeParticipant(reader)
            try await save(structure)
        }
    }

    func setAllowsAccessRequests(_ allowed: Bool, fridgeID: UUID) async throws {
        let share = try await fetchShare(fridgeID, .inventory)
        share.allowsAccessRequests = allowed
        try await save(share)
    }

    func stopSharing(fridgeID: UUID) async throws {
        let ids = [SharedZoneKind.inventory, .structure].map {
            CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: SharedZone.id(fridgeID: fridgeID, kind: $0))
        }
        let (_, results) = try await database.modifyRecords(saving: [], deleting: ids, atomically: false)
        for result in results.values {
            do {
                try result.get()
            } catch let error as CKError where error.code == .unknownItem {
                continue // already gone
            }
        }
    }

    // MARK: Helpers

    private func fetchShare(_ fridgeID: UUID, _ kind: SharedZoneKind) async throws -> CKShare {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: SharedZone.id(fridgeID: fridgeID, kind: kind))
        guard let share = try await database.record(for: id) as? CKShare else { throw ShareAdministrationError.serverFailure }
        return share
    }

    private func save(_ share: CKShare) async throws {
        let (results, _) = try await database.modifyRecords(saving: [share], deleting: [])
        for result in results.values {
            do {
                _ = try result.get()
            } catch let error as CKError where error.code == .serverRecordChanged {
                throw ShareAdministrationError.personGone // someone else changed the share: refresh and retry
            }
        }
    }

    /// Stable within a fetch, never shown or logged.
    private static func key(_ lookup: CKUserIdentity.LookupInfo) -> String {
        lookup.userRecordID?.recordName ?? lookup.emailAddress ?? lookup.phoneNumber ?? ""
    }

    private static func key(_ identity: CKUserIdentity) -> String {
        identity.userRecordID?.recordName ?? identity.lookupInfo.map(key) ?? ""
    }

    private static func name(_ components: PersonNameComponents?, contact: CNContact?) -> String {
        if let contact {
            let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            if !full.isEmpty { return full }
        }
        if let components {
            let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !formatted.isEmpty { return formatted }
        }
        return "iCloud 使用者"
    }
}
