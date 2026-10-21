import SwiftData
import UIKit
import XCTest
@testable import FoodManager

/// Test double: a real SwiftData food store whose reads, writes or deletes can be made to fail.
final class FlakyFoodStore: FoodStore {
    struct Failure: Error {}
    let base: FoodStore
    var failReads = false
    var failWrites = false
    var failDeletes = false

    init(base: FoodStore) { self.base = base }

    func activeItems(fridgeID: UUID) throws -> [FoodItem] {
        if failReads { throw Failure() }
        return try base.activeItems(fridgeID: fridgeID)
    }

    func consumedItems(fridgeID: UUID) throws -> [FoodItem] {
        if failReads { throw Failure() }
        return try base.consumedItems(fridgeID: fridgeID)
    }

    func upsert(_ item: FoodItem) throws {
        if failWrites { throw Failure() }
        try base.upsert(item)
    }

    func delete(id: UUID) throws {
        if failDeletes { throw Failure() }
        try base.delete(id: id)
    }
}

/// Phase 3 critical fixes: no silent in-memory fallback, no false success, explicit load states.
final class ReliabilityTests: XCTestCase {
    private var fridge: Fridge!
    private var flaky: FlakyFoodStore!
    private var inventory: FoodInventoryService!

    override func setUpWithError() throws {
        fridge = FridgeFactory.makeDefault()
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        flaky = FlakyFoodStore(base: SwiftDataFoodStore(container: container))
        inventory = FoodInventoryService(store: flaky, fridgeID: fridge.id, compartments: { [unowned self] in self.fridge.allCompartments })
    }

    private func draft(_ name: String) -> FoodDraft {
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = name
        return draft
    }

    // MARK: 1–3 persistence availability

    func testPersistentStoreFailureIsReportedNotReplacedWithMemory() {
        struct OpenFailure: Error {}
        let persistence = AppPersistence(mode: .persistent) { throw OpenFailure() }
        XCTAssertFalse(persistence.open().isAvailable)
        guard case .failure = AppBootstrap.start(persistence) else { return XCTFail("must not succeed with temporary storage") }
    }

    func testRetryRecoversOncePersistentStoreOpens() throws {
        var attempts = 0
        let persistence = AppPersistence(mode: .persistent) {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
            return try SwiftDataFridgeStore.makeContainer(inMemory: true)
        }
        guard case .failure = AppBootstrap.start(persistence) else { return XCTFail() }
        guard case let .success(session) = AppBootstrap.start(persistence) else { return XCTFail("retry should recover") }
        XCTAssertEqual(session.mode, .persistent)
        XCTAssertEqual(attempts, 2)
    }

    func testInMemoryModeIsExplicit() {
        XCTAssertEqual(AppPersistence.production().mode, .persistent)
        XCTAssertEqual(AppPersistence.inMemoryForTesting().mode, .inMemoryForTesting)
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        XCTAssertEqual(session.mode, .inMemoryForTesting)
    }

    func testRetryDoesNotTouchExistingStoreFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.store")
        let original = try SwiftDataFridgeStore(container: SwiftDataFridgeStore.makeContainer(url: url)).loadOrCreateFridge()

        var fail = true
        let persistence = AppPersistence(mode: .persistent) {
            if fail { throw CocoaError(.fileLocking) }
            return try SwiftDataFridgeStore.makeContainer(url: url)
        }
        _ = AppBootstrap.start(persistence)
        fail = false
        guard case let .success(session) = AppBootstrap.start(persistence) else { return XCTFail() }
        XCTAssertEqual(session.loadResult.fridge, original, "existing data survives a failed open + retry")
    }

    // MARK: 4–7 failed operations never look successful

    func testCreateFailureLeavesInventoryUnchangedAndPostsNothing() {
        flaky.failWrites = true
        let observer = expectation(forNotification: .foodInventoryDidChange, object: inventory)
        observer.isInverted = true
        XCTAssertThrowsError(try inventory.add(draft("牛奶")))
        XCTAssertTrue(inventory.items.isEmpty)
        wait(for: [observer], timeout: 0.2)
    }

    func testEditConsumeDeleteFailuresKeepTheRecord() throws {
        let milk = try inventory.add(draft("牛奶"))
        flaky.failWrites = true
        flaky.failDeletes = true
        var edit = FoodDraft(item: milk)
        edit.name = "鮮奶"
        XCTAssertThrowsError(try inventory.update(milk.id, with: edit))
        XCTAssertThrowsError(try inventory.markConsumed(milk.id))
        XCTAssertThrowsError(try inventory.delete(milk.id))
        XCTAssertThrowsError(try inventory.move(milk.id, to: fridge.cabinetCompartments[1].id))
        XCTAssertEqual(inventory.items, [milk])
    }

    func testEditorStaysOpenAndKeepsInputWhenOperationsFail() throws {
        let milk = try inventory.add(draft("牛奶"))
        let editor = FoodEditorViewController(mode: .edit(foodID: milk.id), inventory: inventory,
                                              compartments: fridge.allCompartments)
        var finished = false
        editor.onFinished = { finished = true }
        editor.loadViewIfNeeded()
        editor.draft.name = "使用者輸入"
        flaky.failWrites = true
        flaky.failDeletes = true

        guard case .failure = editor.submitSave() else { return XCTFail() }
        guard case .failure = editor.submitConsumed() else { return XCTFail() }
        guard case .failure = editor.submitDelete() else { return XCTFail() }
        XCTAssertFalse(finished)
        XCTAssertEqual(editor.draft.name, "使用者輸入", "input preserved after failure")
        XCTAssertFalse(editor.isSubmitting, "controls re-enabled for another attempt")

        flaky.failWrites = false
        XCTAssertEqual(editor.submitSave(), .success)
        XCTAssertEqual(inventory.item(id: milk.id)?.name, "使用者輸入")
    }

    func testEditorAddFailureReportsError() {
        let editor = FoodEditorViewController(mode: .add(compartmentID: fridge.cabinetCompartments[0].id), inventory: inventory,
                                              compartments: fridge.allCompartments)
        editor.loadViewIfNeeded()
        editor.draft.name = "蛋"
        flaky.failWrites = true
        XCTAssertEqual(editor.submitSave(), .failure("儲存失敗，資料沒有變更。請再試一次。"))
        XCTAssertTrue(inventory.items.isEmpty)
    }

    // MARK: 8–9 load states

    func testLoadFailureIsNotEmptyAndKeepsPreviousData() throws {
        let milk = try inventory.add(draft("牛奶"))
        XCTAssertEqual(inventory.loadState, .loaded)
        flaky.failReads = true
        XCTAssertFalse(inventory.reload())
        XCTAssertEqual(inventory.loadState, .failed)
        XCTAssertFalse(inventory.isEmpty, "a failed read is never an empty fridge")
        XCTAssertEqual(inventory.items, [milk], "valid on-screen data is not replaced by an empty list")
    }

    func testInitialLoadFailureThenRetry() throws {
        try inventory.add(draft("牛奶"))
        flaky.failReads = true
        let fresh = FoodInventoryService(store: flaky, fridgeID: fridge.id, compartments: { [unowned self] in self.fridge.allCompartments })
        XCTAssertEqual(fresh.loadState, .failed)
        XCTAssertFalse(fresh.isEmpty)
        flaky.failReads = false
        let posted = expectation(forNotification: .foodInventoryDidChange, object: fresh)
        fresh.retryLoading()
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(fresh.loadState, .loaded)
        XCTAssertEqual(fresh.items.map(\.name), ["牛奶"])
    }

    func testEmptyOnlyAfterSuccessfulRead() {
        XCTAssertEqual(inventory.loadState, .loaded)
        XCTAssertTrue(inventory.isEmpty)
    }
}
