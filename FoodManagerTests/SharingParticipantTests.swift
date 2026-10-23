import CloudKit
import SwiftData
import XCTest
@testable import FoodManager

/// Phase 5D-4: opening an invitation link, requesting access, waiting, joining (inventory, then the verified
/// structure share), leaving, and the foreground fallback fetch. CloudKit is faked; joining across two real iCloud
/// accounts still has to be tested on two iOS 26 devices.
final class SharingParticipantTests: XCTestCase {
    private final class FakeParticipantCloud: ParticipantCloud {
        /// What the server shows this account per link (missing = not visible: not approved yet).
        var visible: [URL: ShareInvitationInfo] = [:]
        var requested: [URL] = []
        var accepted: [URL] = []
        var left: [(UUID, String)] = []
        var fetches = 0
        var onFetch: (() throws -> Void)?

        func metadata(for url: URL) async throws -> ShareInvitationInfo {
            guard let info = visible[url] else { throw CKError(.unknownItem) }
            return info
        }
        func accept(_ url: URL) async throws { accepted.append(url) }
        func requestAccess(_ url: URL) async throws { requested.append(url) }
        func leave(fridgeID: UUID, ownerName: String) async throws { left.append((fridgeID, ownerName)) }
        func fetchNow() async throws {
            fetches += 1
            try onFetch?()
        }
    }

    private final class IdleCloud: SharingCloud {
        var isReady = true
        func upload(fridgeID: UUID, records: [CKRecord.ID]) async throws {}
        func createShares(fridgeID: UUID, title: String) async throws -> (invitation: URL, structure: URL) { throw SharingServiceError.shareFailed }
        func rollback(fridgeID: UUID) {}
        func resetZones(fridgeID: UUID) async throws {}
    }

    private let owner = "_owner"
    private let link = URL(string: "https://www.icloud.com/share/0abcINVENTORY")!
    private let structureLink = URL(string: "https://www.icloud.com/share/0abcSTRUCTURE")!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeService(policy: SharingPolicy? = nil, personalFridges: Int = 1) throws -> (SharingService, FakeParticipantCloud) {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let personal = SwiftDataFridgeStore(container: container)
        for index in 0..<personalFridges { try personal.create(FridgeFactory.makeDefault(name: "個人\(index)")) }
        let cloud = FakeParticipantCloud()
        let service = SharingService(policy: policy ?? SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false,
                                                                     accessRequestsSupported: true),
                                     inventory: SharedInventory(store: SharedStore(container: try SharedStore.makeContainer(inMemory: true))),
                                     cloud: IdleCloud(), personal: personal, hasPremium: { false }, snapshots: nil,
                                     defaults: UserDefaults(suiteName: "SharingParticipantTests-\(UUID().uuidString)")!,
                                     participantCloud: cloud)
        return (service, cloud)
    }

    private func approve(_ fridgeID: UUID, in cloud: FakeParticipantCloud) {
        cloud.visible[link] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: fridgeID, kind: .inventory, ownerName: owner),
                                                  isOwner: false, isMember: true)
    }

    /// What the shared database delivers once the inventory zone is readable.
    private func deliverInventory(_ fridge: Fridge, to service: SharingService) throws {
        let link = SharedRecordCoder.encodeStructureLink(fridgeID: fridge.id, url: structureLink, ownerName: owner, systemFields: nil)
        try service.inventory.store.apply(modifications: [link], deletions: [], scope: .shared)
    }

    private func deliverStructure(_ fridge: Fridge, to service: SharingService) throws {
        let record = SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                                 layoutData: try StoredLayout.encode(fridge), createdAt: date, updatedAt: date),
                                              ownerName: owner, systemFields: nil)
        try service.inventory.store.apply(modifications: [record], deletions: [], scope: .shared)
    }

    // MARK: Request and wait

    func testUnapprovedLinkSendsARequestAndShowsNothing() async throws {
        let (service, cloud) = try makeService()
        let outcome = try await service.join(url: link)
        XCTAssertEqual(outcome, .waitingForApproval)
        XCTAssertEqual(cloud.requested, [link])
        XCTAssertTrue(cloud.accepted.isEmpty, "holding the link grants nothing")
        XCTAssertTrue(try service.inventory.loadAll().isEmpty, "no inventory data before approval")
        XCTAssertEqual(service.inactiveEntries().map(\.ownership), [.pendingInvitation])
        XCTAssertEqual(service.inactiveEntries().first?.ownership.selectorLabel, "等待主人同意")
        XCTAssertEqual(try service.inventory.store.reservedSlots(), 1, "a waiting request holds a slot")

        // Opening the same link again doesn't add a second request.
        _ = try await service.join(url: link)
        XCTAssertEqual(service.invitations().count, 1)
    }

    func testApprovalIsPickedUpAndStructureJoinedAfterVerification() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault(name: "爸媽家")
        _ = try await service.join(url: link)

        // Not approved yet: nothing happens.
        let none = await service.checkPendingInvitations()
        XCTAssertTrue(none.isEmpty)

        approve(fridge.id, in: cloud)
        cloud.onFetch = { [unowned self] in try self.deliverInventory(fridge, to: service) }
        cloud.visible[structureLink] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: owner),
                                                           isOwner: false, isMember: true)
        let joined = await service.checkPendingInvitations()
        XCTAssertEqual(joined, [fridge.id])
        XCTAssertEqual(cloud.accepted, [link, structureLink], "inventory first, then the verified structure share")
        XCTAssertTrue(service.invitations().isEmpty)
        XCTAssertEqual(service.inventory.ownership(of: fridge.id), .pendingInvitation, "until the structure arrives")

        try deliverStructure(fridge, to: service)
        XCTAssertEqual(service.inventory.ownership(of: fridge.id), .sharedParticipant)
        XCTAssertEqual(try service.inventory.loadAll().map(\.fridge.name), ["爸媽家"])
    }

    func testAForgedStructureLinkIsNeverJoined() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault()
        approve(fridge.id, in: cloud)
        _ = try await service.join(url: link)
        try deliverInventory(fridge, to: service)
        // The link points at somebody else's structure zone (a member could have written it).
        cloud.visible[structureLink] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: UUID(), kind: .structure, ownerName: "_mallory"),
                                                           isOwner: false, isMember: true)
        cloud.accepted = []
        await service.continueStructureJoins()
        XCTAssertTrue(cloud.accepted.isEmpty)

        // Right zone, wrong owner: also refused.
        cloud.visible[structureLink] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: "_mallory"),
                                                           isOwner: false, isMember: true)
        await service.continueStructureJoins()
        XCTAssertTrue(cloud.accepted.isEmpty)
    }

    func testApprovedLinkJoinsDirectly() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault()
        approve(fridge.id, in: cloud)
        let outcome = try await service.join(url: link)
        XCTAssertEqual(outcome, .joined(fridge.id))
        XCTAssertTrue(cloud.requested.isEmpty)
        XCTAssertEqual(cloud.fetches, 1)

        try deliverInventory(fridge, to: service)
        try deliverStructure(fridge, to: service)
        let again = try await service.join(url: link)
        XCTAssertEqual(again, .alreadyJoined(fridge.id))
    }

    func testLinksThatArentInvitationsAreRejected() async throws {
        let (service, cloud) = try makeService()
        for text in ["https://example.com/share/x", "http://www.icloud.com/share/x"] {
            do {
                _ = try await service.join(url: URL(string: text)!)
                XCTFail(text)
            } catch {
                XCTAssertEqual(error as? JoinError, .invalidLink)
            }
        }
        // A structure share link can't be used to join.
        let fridge = FridgeFactory.makeDefault()
        cloud.visible[link] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: fridge.id, kind: .structure, ownerName: owner),
                                                  isOwner: false, isMember: true)
        do {
            _ = try await service.join(url: link)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? JoinError, .invalidLink)
        }
        XCTAssertTrue(cloud.accepted.isEmpty && cloud.requested.isEmpty)
    }

    func testOwnLinkIsRecognised() async throws {
        let (service, cloud) = try makeService()
        cloud.visible[link] = ShareInvitationInfo(zoneID: SharedZone.id(fridgeID: UUID(), kind: .inventory), isOwner: true, isMember: true)
        let outcome = try await service.join(url: link)
        XCTAssertEqual(outcome, .ownFridge)
        XCTAssertTrue(cloud.accepted.isEmpty)
    }

    // MARK: Limit and gate

    func testJoiningRespectsTheTwoFridgeLimit() async throws {
        let (service, cloud) = try makeService(personalFridges: 2)
        do {
            _ = try await service.join(url: link)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? JoinError, .limitReached)
        }
        approve(UUID(), in: cloud)
        do {
            _ = try await service.join(url: link)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? JoinError, .limitReached)
        }
        XCTAssertTrue(cloud.requested.isEmpty && cloud.accepted.isEmpty)
    }

    func testDisabledBuildIgnoresInvitationLinks() async throws {
        let off = SharingPolicy(sharedRefrigeratorsEnabled: false, sharedRefrigeratorsRequirePremium: true, accessRequestsSupported: true)
        let (service, cloud) = try makeService(policy: off)
        do {
            _ = try await service.join(url: link)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharingServiceError, .notAllowed(.disabled), "no paywall, no request")
        }
        let joined = await service.checkPendingInvitations()
        XCTAssertTrue(joined.isEmpty)
        XCTAssertTrue(cloud.requested.isEmpty && cloud.accepted.isEmpty)
    }

    func testDirectoryCountsWaitingRequests() async throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let (service, _) = try makeService()
        _ = try await service.join(url: link)
        guard case let .success(session) = AppBootstrap.makeSession(container: container, mode: .inMemoryForTesting,
                                                                    selection: InMemoryFridgeSelectionStore(), sharing: service) else {
            return XCTFail()
        }
        XCTAssertEqual(session.directory.fridges.count, 1)
        XCTAssertFalse(session.directory.canAddFridge, "1 fridge + 1 waiting request = 2")
        try service.cancelInvitation(service.invitations()[0].id)
        XCTAssertTrue(session.directory.canAddFridge)
    }

    // MARK: Leaving

    func testLeavingEndsAccessThenRemovesTheLocalCopy() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault()
        approve(fridge.id, in: cloud)
        _ = try await service.join(url: link)
        try deliverInventory(fridge, to: service)
        try deliverStructure(fridge, to: service)
        try await service.leave(fridgeID: fridge.id)
        XCTAssertEqual(cloud.left.map(\.0), [fridge.id])
        XCTAssertEqual(cloud.left.map(\.1), [owner])
        XCTAssertNil(service.inventory.ownership(of: fridge.id))
    }

    func testRevokedFridgeIsRemovedLocallyWithoutTheServer() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault()
        try deliverStructure(fridge, to: service)
        try service.inventory.store.zoneWasDeleted(SharedZone.id(fridgeID: fridge.id, kind: .inventory, ownerName: owner), scope: .shared)
        XCTAssertEqual(service.inactiveEntries().map(\.ownership), [.unavailableOrRevoked])
        try await service.leave(fridgeID: fridge.id)
        XCTAssertTrue(cloud.left.isEmpty)
        XCTAssertTrue(service.inactiveEntries().isEmpty)
    }

    func testOwnerCantLeaveTheirOwnFridge() async throws {
        let (service, cloud) = try makeService()
        let fridge = FridgeFactory.makeDefault()
        let record = SharedRecordCoder.encode(SharedFridgeFields(id: fridge.id, name: fridge.name, templateID: fridge.templateID,
                                                                 layoutData: try StoredLayout.encode(fridge), createdAt: date, updatedAt: date),
                                              ownerName: CKCurrentUserDefaultName, systemFields: nil)
        try service.inventory.store.apply(modifications: [record], deletions: [], scope: .private)
        do {
            try await service.leave(fridgeID: fridge.id)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SharedStoreError, .ownerOnly)
        }
        XCTAssertTrue(cloud.left.isEmpty)
    }

    // MARK: Foreground fallback

    @MainActor
    func testPollerFetchesOnlyWhileVisibleAndActive() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var fetches = 0
        let poller = SharedFetchPoller(now: { clock }) { fetches += 1 }
        poller.update(sharedFridgeVisible: true)
        XCTAssertFalse(poller.isRunning, "app not active yet")
        poller.update(appActive: true)
        XCTAssertTrue(poller.isRunning)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetches, 1)

        clock.addTimeInterval(10)
        poller.tickNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetches, 1, "not before 30 s")
        clock.addTimeInterval(25)
        poller.tickNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetches, 2)

        poller.update(sharedFridgeVisible: false)
        XCTAssertFalse(poller.isRunning, "stops as soon as no shared fridge is visible")
    }
}
