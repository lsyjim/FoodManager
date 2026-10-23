import CloudKit
import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5D-3: owner-only membership management, stopping sharing and the structure-link record. The CloudKit
/// share operations are faked; approving real requesters needs two devices with different iCloud accounts.
final class SharingMembershipTests: XCTestCase {
    private final class FakeAdministrator: ShareAdministering {
        var calls: [String] = []
        var failNext = false
        var overviewResult = ShareOverview(requesters: [SharePerson(id: "r1", name: "小明", contactDetail: "ming@example.com")],
                                           members: [], blocked: [], allowsAccessRequests: true)

        private func record(_ call: String) throws {
            calls.append(call)
            if failNext {
                failNext = false
                throw ShareAdministrationError.serverFailure
            }
        }

        func overview(fridgeID: UUID) async throws -> ShareOverview { try record("overview"); return overviewResult }
        func approve(requesterID: String, fridgeID: UUID) async throws { try record("approve:\(requesterID)") }
        func deny(requesterID: String, fridgeID: UUID) async throws { try record("deny:\(requesterID)") }
        func block(requesterID: String, fridgeID: UUID) async throws { try record("block:\(requesterID)") }
        func unblock(blockedID: String, fridgeID: UUID) async throws { try record("unblock:\(blockedID)") }
        func remove(memberID: String, fridgeID: UUID) async throws { try record("remove:\(memberID)") }
        func setAllowsAccessRequests(_ allowed: Bool, fridgeID: UUID) async throws { try record("allow:\(allowed)") }
        func stopSharing(fridgeID: UUID) async throws { try record("stop") }
    }

    private final class IdleCloud: SharingCloud {
        var isReady = true
        func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {}
        func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) {
            throw SharingServiceError.shareFailed
        }
        func rollback(fridgeID: UUID) {}
        func resetZones(fridgeID: UUID) async throws {}
    }

    private let invitation = URL(string: "https://www.icloud.com/share/inv")!
    private let structureURL = URL(string: "https://www.icloud.com/share/str")!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func fridgeRecord(_ fridge: Fridge, ownerName: String) throws -> CKRecord {
        SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                    layoutData: try StoredLayout.encode(fridge), createdAt: date, updatedAt: date),
                                 ownerName: ownerName, systemFields: nil)
    }

    private func makeService(sharedFridge: Fridge? = nil) throws -> (SharingService, SharedInventory, FakeAdministrator, () -> [SharedInventory.Change]) {
        let inventory = SharedInventory(store: SharedStore(container: try SharedStore.makeContainer(inMemory: true)))
        var changes: [SharedInventory.Change] = []
        inventory.onLocalChange = { changes.append($0) }
        if let sharedFridge {
            try inventory.store.apply(modifications: [try fridgeRecord(sharedFridge, ownerName: CKCurrentUserDefaultName)],
                                      deletions: [], scope: .private)
            try inventory.markShared(sharedFridge.id, invitationURL: invitation, structureURL: structureURL)
        }
        let administrator = FakeAdministrator()
        let service = SharingService(policy: SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false,
                                                           accessRequestsSupported: true),
                                     inventory: inventory, cloud: IdleCloud(),
                                     personal: SwiftDataFridgeStore(container: try SwiftDataFridgeStore.makeContainer(inMemory: true)),
                                     hasPremium: { false }, snapshots: nil,
                                     defaults: UserDefaults(suiteName: "SharingMembershipTests-\(UUID().uuidString)")!,
                                     administrator: administrator)
        return (service, inventory, administrator, { changes })
    }

    // MARK: Owner-only management

    func testOwnerManagesRequestsAndMembers() async throws {
        let fridge = FridgeFactory.makeDefault(name: "全家")
        let (service, _, administrator, _) = try makeService(sharedFridge: fridge)
        let overview = try await service.shareOverview(fridgeID: fridge.id)
        let requester = try XCTUnwrap(overview.requesters.first)
        try await service.approve(requester, fridgeID: fridge.id)
        try await service.deny(requester, fridgeID: fridge.id)
        try await service.block(requester, fridgeID: fridge.id)
        try await service.unblock(requester, fridgeID: fridge.id)
        try await service.remove(SharePerson(id: "m1", name: "成員", contactDetail: nil), fridgeID: fridge.id)
        try await service.setAllowsAccessRequests(false, fridgeID: fridge.id)
        XCTAssertEqual(administrator.calls, ["overview", "approve:r1", "deny:r1", "block:r1", "unblock:r1", "remove:m1", "allow:false"])
    }

    func testNobodyButTheOwnerCanManage() async throws {
        let (service, inventory, administrator, _) = try makeService()
        let personal = UUID()
        do {
            _ = try await service.shareOverview(fridgeID: personal)
            XCTFail("a personal fridge has no members")
        } catch {
            XCTAssertEqual(error as? ShareAdministrationError, .notOwner)
        }

        let theirs = FridgeFactory.makeDefault(name: "朋友的")
        try inventory.store.apply(modifications: [try fridgeRecord(theirs, ownerName: "_friend")], deletions: [], scope: .shared)
        XCTAssertEqual(inventory.ownership(of: theirs.id), .sharedParticipant)
        do {
            try await service.stopSharing(fridgeID: theirs.id)
            XCTFail("a member can't stop sharing")
        } catch {
            XCTAssertEqual(error as? ShareAdministrationError, .notOwner)
        }
        XCTAssertTrue(administrator.calls.isEmpty, "nothing reaches the server")
    }

    func testStopSharingKeepsTheFridgeWithTheOwner() async throws {
        let fridge = FridgeFactory.makeDefault(name: "全家")
        let (service, inventory, administrator, changes) = try makeService(sharedFridge: fridge)
        try await service.stopSharing(fridgeID: fridge.id)
        XCTAssertEqual(administrator.calls, ["stop"])
        XCTAssertEqual(inventory.ownership(of: fridge.id), .personalOwned)
        XCTAssertNil(service.invitationURL(for: fridge.id))
        XCTAssertEqual(try inventory.loadAll().map(\.fridge.id), [fridge.id], "fridge and food stay")
        let linkID = CKRecord.ID(recordName: fridge.id.uuidString, zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory))
        XCTAssertEqual(changes().last?.deletes, [linkID], "the structure link is removed too")
    }

    func testFailedStopChangesNothing() async throws {
        let fridge = FridgeFactory.makeDefault()
        let (service, inventory, administrator, _) = try makeService(sharedFridge: fridge)
        administrator.failNext = true
        do {
            try await service.stopSharing(fridgeID: fridge.id)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ShareAdministrationError, .serverFailure)
        }
        XCTAssertEqual(inventory.ownership(of: fridge.id), .sharedOwned)
        XCTAssertEqual(service.invitationURL(for: fridge.id), invitation)
    }

    // MARK: Structure link

    func testSharingUploadsTheStructureLink() throws {
        let fridge = FridgeFactory.makeDefault()
        let (_, inventory, _, changes) = try makeService(sharedFridge: fridge)
        let linkID = CKRecord.ID(recordName: fridge.id.uuidString, zoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory))
        XCTAssertEqual(changes().last?.saves, [linkID])
        let record = try XCTUnwrap(try inventory.store.outgoingRecord(for: linkID, scope: .private))
        XCTAssertEqual(record.recordType, SharedRecordType.structureLink)
        XCTAssertEqual(record["url"] as? String, structureURL.absoluteString)
    }

    func testMemberLearnsTheStructureLinkBeforeTheStructure() throws {
        let store = SharedStore(container: try SharedStore.makeContainer(inMemory: true))
        let fridge = FridgeFactory.makeDefault(name: "全家")
        let link = SharedRecordCoder.encodeStructureLink(fridgeID: fridge.id, url: structureURL, ownerName: "_owner", systemFields: nil)
        try store.apply(modifications: [link], deletions: [], scope: .shared)
        XCTAssertEqual(try store.ownerships(), [.pendingInvitation], "approved, structure not joined yet")
        XCTAssertNil(try store.outgoingRecord(for: link.recordID, scope: .shared), "members never upload the link")

        try store.apply(modifications: [try fridgeRecord(fridge, ownerName: "_owner")], deletions: [], scope: .shared)
        XCTAssertEqual(try store.ownerships(), [.sharedParticipant])
    }

    func testOnlyICloudLinksInTheRightPlaceAreAccepted() {
        let fridgeID = UUID()
        let valid = SharedRecordCoder.encodeStructureLink(fridgeID: fridgeID, url: structureURL, ownerName: "_o", systemFields: nil)
        XCTAssertEqual(SharedRecordCoder.decode(valid), .structureLink(fridgeID: fridgeID, url: structureURL))

        for text in ["http://www.icloud.com/share/x", "https://evil.example.com/share/x", "https://icloud.com.evil.com/x"] {
            let record = SharedRecordCoder.encodeStructureLink(fridgeID: fridgeID, url: URL(string: text)!, ownerName: "_o", systemFields: nil)
            XCTAssertNil(SharedRecordCoder.decode(record), text)
        }
        let otherName = CKRecord(recordType: SharedRecordType.structureLink,
                                 recordID: CKRecord.ID(recordName: UUID().uuidString,
                                                       zoneID: SharedZone.id(fridgeID: fridgeID, kind: .inventory, ownerName: "_o")))
        otherName["url"] = structureURL.absoluteString
        XCTAssertNil(SharedRecordCoder.decode(otherName), "one link per fridge, named after it")
    }

    func testOwnersOtherDeviceSeesSharingStop() throws {
        let store = SharedStore(container: try SharedStore.makeContainer(inMemory: true))
        let fridge = FridgeFactory.makeDefault()
        try store.apply(modifications: [try fridgeRecord(fridge, ownerName: CKCurrentUserDefaultName)], deletions: [], scope: .private)
        let share = CKShare(recordZoneID: SharedZone.id(fridgeID: fridge.id, kind: .inventory))
        try store.apply(modifications: [share], deletions: [], scope: .private)
        XCTAssertEqual(try store.ownerships(), [.sharedOwned])

        try store.apply(modifications: [], deletions: [(share.recordID, CKRecord.SystemType.share)], scope: .private)
        XCTAssertEqual(try store.ownerships(), [.personalOwned])
    }
}
